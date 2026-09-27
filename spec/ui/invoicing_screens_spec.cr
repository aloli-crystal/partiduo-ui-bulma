# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Clôture du lot 2F — écrans ajoutés à la relecture (D-2F-011) : historique
# de la Facturation à comptabiliser, envoi d'un document par courriel,
# paramètres de facturation, modèles de mise en page.

private alias Inv = Partiduo::Api::Invoicing
private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private def product : Partiduo::Api::Cards::CardView
  Partiduo::Api::Cards.card_by_code(Books.system, "CONSEIL") || begin
    rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
    input = Partiduo::Api::Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id,
      name: "Conseil (heure)", code: "CONSEIL", unit_code: "HUR", sale_price: Books.d("80"), vat_rate_id: rate.id)
    Partiduo::Api::Cards.create_card(Books.system, input).value!
  end
end

private def issued(customer : Partiduo::Api::Cards::CardView, day : String = "2026-02-10") : Inv::DocumentView
  draft = Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
    lines: [Inv::LineInput.new(item_card_id: product.id, quantity: Books.d("1"))])).value!
  Inv.issue(Books.system, draft.id, Inv::IssueInput.new(Books.date(day))).value!
end

private def without_accounting(& : -> T) : T forall T
  Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
  Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
  result = yield
  Partiduo::Api::Modules.activate(Books.system, "ACCOUNTING")
  result
end

describe "Historique de la Facturation à comptabiliser (ADR-006 D2)" do
  it "propose au tableau de bord puis comptabilise les factures émises sans Comptabilité" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    invoice = without_accounting { issued(customer) }
    Acc.entries(Books.system, Acc::EntryQuery.new(source: "invoice:#{invoice.id}")).should be_empty

    browser.get("/").html.should contain("1 opération de la Facturation à comptabiliser")
    page = browser.get("/accounting/invoicing-history").html
    page.should contain("À comptabiliser (Facturation)")
    page.should contain(invoice.number || "")
    page.should contain("Atelier Morel")
    page.should contain("Prêt à comptabiliser")
    page.should contain("Tout comptabiliser")

    response = browser.post("/accounting/invoicing-history/post")
    response.status.should eq(302)
    browser.follow(response).html.should contain("1 opération comptabilisée.")
    Acc.entries(Books.system, Acc::EntryQuery.new(source: "invoice:#{invoice.id}")).size.should eq(1)
    browser.get("/accounting/invoicing-history").html.should contain("Rien à comptabiliser.")
    browser.get("/").html.should_not contain("à comptabiliser")
  end

  it "écarte une opération puis la rend à la liste" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    without_accounting { issued(customer) }
    event_id = Acc.invoicing_history(Books.system).first.event_id

    dismissed = browser.post("/accounting/invoicing-history/#{event_id}/dismiss")
    browser.follow(dismissed).html.should contain("Opération écartée.")
    browser.get("/accounting/invoicing-history").html.should contain("Écarté")
    Acc.invoicing_history(Books.system).should be_empty

    restored = browser.post("/accounting/invoicing-history/#{event_id}/restore")
    browser.follow(restored).html.should contain("Opération rendue à la liste.")
    Acc.invoicing_history(Books.system).map(&.event_id).should eq([event_id])
  end

  it "exige l'écriture des écritures" do
    Books.admin
    profile = PartiduoUi::Accounts.profile("Lecteur", ["accounting.entry.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    PartiduoUi::Accounts.signed_in("bob@example.com").get("/accounting/invoicing-history").status.should eq(403)
  end
end

describe "Envoi, paramètres et modèles de la Facturation (lot 2F)" do
  it "envoie un document émis par courriel, à l'adresse du client par défaut" do
    browser = Books.admin
    transport = Inv::MemoryTransport.new
    previous = Inv.mail_transport
    Inv.mail_transport = transport
    begin
      Inv.update_settings(Books.system, Inv.settings(Books.system).to_input.copy_with(sender_email: "factures@brunet.test")).value!
      customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL", "compta@morel.test")
      invoice = issued(customer)
      browser.get("/invoicing/documents/#{invoice.id}").html.should contain(%(href="/invoicing/documents/#{invoice.id}/send"))
      form = browser.get("/invoicing/documents/#{invoice.id}/send").html
      form.should contain(%(value="compta@morel.test"))
      form.should contain("Texte par défaut, dans la langue du document")

      refused = browser.post("/invoicing/documents/#{invoice.id}/send", {"to" => "pas-une-adresse", "cc" => "", "subject" => "", "body" => ""})
      refused.status.should eq(422)
      refused.html.should contain(I18n.t("invoicing.errors.mail.invalid_address"))

      sent = browser.post("/invoicing/documents/#{invoice.id}/send",
        {"to" => "compta@morel.test", "cc" => "associe@morel.test", "subject" => "", "body" => ""})
      sent.status.should eq(302)
      browser.follow(sent).html.should contain("Document envoyé à compta@morel.test, associe@morel.test.")
      transport.messages.size.should eq(1)
      transport.messages.first.subject.should contain(invoice.number || "")
      Inv.document(Books.system, invoice.id).status.should eq("sent")
    ensure
      Inv.mail_transport = previous
    end
  end

  it "modifie les paramètres de facturation, erreurs sous leur champ" do
    browser = Books.admin
    page = browser.get("/invoicing/settings").html
    page.should contain("Paramètres de facturation")
    page.should contain(%(name="payment_terms_days"))
    page.should contain("%{number}")
    values = {
      "payment_terms_days" => "400", "quote_validity_days" => "30", "late_penalty_rate" => "", "early_discount_rate" => "",
      "early_discount_days" => "", "default_operation_category" => "services", "iban" => "", "bic" => "",
      "sender_email" => "", "sender_name" => "", "reminder1_days" => "7", "reminder2_days" => "30",
      "reminder3_days" => "60", "penalty_from_level" => "2", "reminder_subject" => "", "reminder_body" => "",
      "sales_journal_code" => "VT", "bank_journal_code" => "BQ", "customer_account" => "", "sales_account" => "",
      "vat_account" => "", "bank_account" => "",
    }
    refused = browser.post("/invoicing/settings", values)
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("invoicing.errors.settings.days", max: "365"))
    refused.html.should contain(%(value="400"))

    saved = browser.post("/invoicing/settings", values.merge({"payment_terms_days" => "45", "late_penalty_rate" => "10,5",
                                                              "vat_on_debits" => "1"}))
    saved.status.should eq(302)
    browser.follow(saved).html.should contain("Paramètres enregistrés.")
    settings = Inv.settings(Books.system)
    settings.payment_terms_days.should eq(45)
    settings.late_penalty_rate.should eq(Books.d("10.5"))
    settings.vat_on_debits.should be_true
  end

  it "crée, modifie et supprime un modèle de mise en page" do
    browser = Books.admin
    browser.get("/invoicing/templates").html.should contain("Aucun modèle")
    browser.get("/invoicing/templates/new").html.should contain(%(name="primary_color"))
    refused = browser.post("/invoicing/templates/new", {"name" => "Sobre", "primary_color" => "bleu", "text_color" => "#1a1a1a",
                                                        "header_text" => "", "footer_text" => ""})
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("invoicing.errors.layout.color"))

    created = browser.post("/invoicing/templates/new", {"name" => "Sobre", "primary_color" => "#224466", "text_color" => "#1a1a1a",
                                                        "header_text" => "Atelier", "footer_text" => "Merci", "is_default" => "1"})
    created.status.should eq(302)
    browser.follow(created).html.should contain("Modèle Sobre créé.")
    layout = Inv.layouts(Books.system).first
    layout.is_default.should be_true

    edited = browser.post("/invoicing/templates/#{layout.id}/edit", {"name" => "Sobre bleu", "primary_color" => "#224466",
                                                                     "text_color" => "#000000", "header_text" => "", "footer_text" => ""})
    edited.status.should eq(302)
    Inv.layout(Books.system, layout.id).name.should eq("Sobre bleu")
    Inv.layout(Books.system, layout.id).is_default.should be_false

    deleted = browser.post("/invoicing/templates/#{layout.id}/delete")
    browser.follow(deleted).html.should contain("Modèle Sobre bleu supprimé.")
    Inv.layouts(Books.system).should be_empty
  end

  it "répond 403 aux écrans de paramétrage sans le droit" do
    Books.admin
    profile = PartiduoUi::Accounts.profile("Lecteur factures", ["invoicing.invoice.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    bob.get("/invoicing/settings").status.should eq(403)
    bob.get("/invoicing/templates").status.should eq(403)
  end
end
