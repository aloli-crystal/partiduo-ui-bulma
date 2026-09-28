# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# ADR-004 D9 révisé (28 septembre 2026) dans l'interface : nature du client
# sur la fiche, saisie express d'un particulier depuis la facture, copie PDF
# doublant la plateforme (paramètres, téléchargement, envoi). DECISIONS
# D-FIN-001 à D-FIN-003.

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books

private def platform_invoice : Inv::DocumentView
  customers = PartiduoUi::Reference.category("CUSTOMER")
  customer = Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(
    category_id: customers.id, name: "Atelier Morel", code: "CLI-MOREL", siren: "443061841",
    email: "compta@morel.test")).value!
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  item = Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(
    category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil", code: "CONSEIL", unit_code: "HUR",
    sale_price: Books.d("80"), vat_rate_id: rate.id)).value!
  draft = Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
    lines: [Inv::LineInput.new(item_card_id: item.id, quantity: Books.d("1"))])).value!
  Inv.issue(Books.system, draft.id, Inv::IssueInput.new(Books.date("2026-09-15"))).value!
end

describe "Nature du client et copie PDF (ADR-004 D9 révisé, interface)" do
  it "choisit la nature d'un client sur sa fiche et refuse la copie PDF client par client" do
    browser = Books.admin
    customers = PartiduoUi::Reference.category("CUSTOMER")
    form = browser.get("/cards/new?category=#{customers.id}").html
    form.should contain(%(name="customer_nature"))
    form.should contain("Administration publique")
    form.should contain(%(name="pdf_copy"))
    suppliers = PartiduoUi::Reference.category("SUPPLIER")
    browser.get("/cards/new?category=#{suppliers.id}").html.should_not contain(%(name="customer_nature"))

    response = browser.post("/cards/new", {"category_id" => customers.id.to_s, "name" => "Ville de Paris",
                                           "enabled" => "1", "siren" => "217500016", "customer_nature" => "public"})
    response.status.should eq(302)
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    card = Partiduo::Api::Cards.card(Books.system, id)
    {card.customer_nature, card.pdf_copy}.should eq({"public", false})
    page = browser.follow(response).html
    page.should contain("Nature du client")
    page.should contain("Administration publique")
  end

  it "crée un particulier depuis la facture et remplit le champ « Client »" do
    browser = Books.admin
    browser.get("/invoicing/documents/new?kind=invoice").html.should contain("Nouveau client particulier")
    created = browser.htmx_post("/invoicing/express-customer", {"express_name" => "Jeanne Martin",
                                                                "express_email" => "jeanne@exemple.test",
                                                                "express_city" => "Nantes", "express_postcode" => "44000"})
    created.status.should eq(200)
    card = Partiduo::Api::Cards.cards(Books.system, Partiduo::Api::Cards::CardQuery.new(search: "Jeanne Martin")).first
    card.customer_nature.should eq("individual")
    created.content.should contain(%(hx-swap-oob="true"))
    created.content.should contain(%(value="#{card.code}"))

    refused = browser.htmx_post("/invoicing/express-customer", {"express_name" => "", "express_email" => "x"})
    refused.content.should contain("Le nom est obligatoire.")
  end

  it "règle la période de la copie PDF dans les paramètres de facturation" do
    browser = Books.admin
    page = browser.get("/invoicing/settings").html
    page.should contain(%(name="pdf_copy_enabled"))
    page.should contain(%(name="pdf_copy_until"))
    values = Inv.settings(Books.system)
    data = {
      "payment_terms_days" => "30", "quote_validity_days" => "30", "late_penalty_rate" => "", "early_discount_rate" => "",
      "early_discount_days" => "", "default_operation_category" => "services", "iban" => "", "bic" => "",
      "sender_email" => "", "sender_name" => "", "reminder1_days" => "7", "reminder2_days" => "30",
      "reminder3_days" => "60", "penalty_from_level" => "2", "reminder_subject" => "", "reminder_body" => "",
      "sales_journal_code" => values.sales_journal_code, "bank_journal_code" => values.bank_journal_code,
      "customer_account" => "", "sales_account" => "", "vat_account" => "", "bank_account" => "",
      "pdf_copy_enabled" => "1", "pdf_copy_from" => "2026-09-01", "pdf_copy_until" => "2026-08-01",
    }
    refused = browser.post("/invoicing/settings", data)
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("invoicing.errors.settings.pdf_copy_period"))
    saved = browser.post("/invoicing/settings", data.merge({"pdf_copy_until" => "2027-08-31"}))
    saved.status.should eq(302)
    Inv.settings(Books.system).pdf_copy_until.should eq(Books.date("2027-08-31"))
  end

  it "télécharge et envoie la copie PDF d'une facture au canal plateforme" do
    browser = Books.admin
    transport = Inv::MemoryTransport.new
    previous = Inv.mail_transport
    Inv.mail_transport = transport
    begin
      Inv.update_settings(Books.system, Inv.settings(Books.system).to_input.copy_with(sender_email: "factures@brunet.test")).value!
      invoice = platform_invoice
      page = browser.get("/invoicing/documents/#{invoice.id}").html
      page.should contain(%(href="/invoicing/documents/#{invoice.id}/pdf-copy"))
      page.should contain("Copie PDF prévue")
      # Date absente : pas de ligne vide (une chaîne vide est vraie dans un gabarit).
      page.should_not contain(I18n.t("ui.invoicing.validity_date"))
      # Mentions : montants et dates présentés comme à l'écran.
      page.should contain("40,00 €")
      page.should_not contain("40.0 EUR")
      pdf = browser.get("/invoicing/documents/#{invoice.id}/pdf-copy")
      pdf.status.should eq(200)
      pdf.content_type.should start_with("application/pdf")
      pdf.headers["Content-Disposition"].should contain("-copie.pdf")

      page.should contain(I18n.t("ui.invoicing.pdf_copy_send"))
      page.should_not contain(I18n.t("ui.invoicing.pdf_copy_resend"))

      sent = browser.post("/invoicing/documents/#{invoice.id}/send-pdf-copy")
      shown = browser.follow(sent).html
      shown.should contain("Copie PDF envoyée.")
      transport.messages.size.should eq(1)
      transport.messages.first.to.should eq(["compta@morel.test"])
      # « Copie PDF envoyée le… » et « Renvoyer la copie ».
      shown.should contain("Copie PDF envoyée le ")
      shown.should contain("compta@morel.test")
      shown.should contain(I18n.t("ui.invoicing.pdf_copy_resend"))
    ensure
      Inv.mail_transport = previous
    end
  end
end
