# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books

private def item(code : String = "CONSEIL", price : String = "80") : Partiduo::Api::Cards::CardView
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  input = Partiduo::Api::Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil (heure)",
    code: code, unit_code: "HUR", sale_price: Books.d(price), vat_rate_id: rate.id)
  Partiduo::Api::Cards.create_card(Books.system, input).value!
end

private def quote_values(customer : String, extra = {} of String => String) : Hash(String, String)
  {"kind" => "quote", "customer" => customer, "issue_date" => "", "delivery_date" => "", "validity_date" => "",
   "operation_category" => "services", "global_discount" => "", "buyer_reference" => "BC-12", "order_reference" => "",
   "notes" => "", "line-0-item" => "CONSEIL", "line-0-description" => "", "line-0-quantity" => "10", "line-0-unit" => "",
   "line-0-unit_price" => "", "line-0-discount" => "", "line-0-vat_rate_id" => ""}.merge(extra)
end

# Facture émise par le contrat, de `amount` HT, datée et échue dans le passé.
private def issued_invoice(customer : Partiduo::Api::Cards::CardView, day : String = "2026-01-05", due : String = "2026-01-20") : Inv::DocumentView
  item unless Partiduo::Api::Cards.card_by_code(Books.system, "CONSEIL")
  product = Partiduo::Api::Cards.card_by_code(Books.system, "CONSEIL") || raise "article absent"
  draft = Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
    lines: [Inv::LineInput.new(item_card_id: product.id, quantity: Books.d("1"))], due_date: Books.date(due))).value!
  Inv.issue(Books.system, draft.id, Inv::IssueInput.new(Books.date(day))).value!
end

describe "Devis et factures (ADR-006 D5)" do
  it "crée un devis au clavier : client et article complétés, totaux par check_document" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    item
    form = browser.get("/invoicing/documents/new?kind=quote").html
    form.should contain("<h1>Devis : nouveau brouillon</h1>")
    form.should contain(%(data-pd-entry))
    form.should contain(%(hx-get="/cards/complete?kind=customer"))
    form.should contain(%(hx-get="/cards/complete?kind=item"))
    form.should contain(%(hx-post="/invoicing/documents/check"))
    form.should contain(%(name="validity_date"))
    form.should contain("Mentions obligatoires")
    browser.get("/cards/complete?kind=item&line-0-item=con").html.should contain(%(<option value="CONSEIL">CONSEIL · Conseil (heure)</option>))

    totals = browser.post("/invoicing/documents/check", quote_values(customer.code), {"HX-Request" => "true"}).html
    totals.should contain("800,00")
    totals.should contain("160,00")
    totals.should contain("960,00")

    refused = browser.post("/invoicing/documents/check", quote_values("INCONNU"), {"HX-Request" => "true"}).html
    refused.should contain("Aucun client « INCONNU ».")

    response = browser.post("/invoicing/documents/new", quote_values(customer.code))
    response.status.should eq(302)
    page = browser.follow(response).html
    page.should contain("Brouillon enregistré : Devis.")
    page.should contain("Valider")
    page.should contain("Conseil (heure)")
    document = Inv.documents(Books.system, Inv::DocumentQuery.new(kind: "quote")).first
    document.buyer_reference.should eq("BC-12")
    document.totals.total_gross.should eq(Books.d("960"))

    edit = browser.get("/invoicing/documents/#{document.id}/edit").html
    edit.should contain(%(value="CLI-MOREL"))
    edit.should contain(%(name="line-0-item" id="pd-dl0-item" value="CONSEIL"))
    edit.should contain("800,00")
    updated = browser.post("/invoicing/documents/#{document.id}/edit", quote_values(customer.code, {"line-0-quantity" => "5"}))
    updated.status.should eq(302)
    Inv.document(Books.system, document.id).totals.total_net.should eq(Books.d("400"))
  end

  it "valide un devis, le transforme en facture, valide la facture et fournit PDF Factur-X et aperçu" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    item
    browser.post("/invoicing/documents/new", quote_values(customer.code))
    quote = Inv.documents(Books.system, Inv::DocumentQuery.new(kind: "quote")).first

    issued = browser.post("/invoicing/documents/#{quote.id}/issue")
    issued.headers["Location"].should eq("/invoicing/documents/#{quote.id}")
    page = browser.follow(issued).html
    year = Time.utc.year
    page.should contain("Document validé : Devis D-#{year}-0001.")
    page.should contain("Transformer en facture")
    page.should contain("Devis accepté")
    page.should contain("Facturer un acompte")

    transformed = browser.post("/invoicing/documents/#{quote.id}/transform?kind=invoice")
    transformed.status.should eq(302)
    invoice_id = PartiduoUi::Reference.id_from(transformed.headers["Location"].sub("/edit", ""))
    edit = browser.follow(transformed).html
    edit.should contain("Brouillon créé : Facture.")
    edit.should contain("Issu du devis D-#{year}-0001")

    browser.post("/invoicing/documents/#{invoice_id}/issue")
    invoice = Inv.document(Books.system, invoice_id)
    invoice.number.should eq("F-#{year}-0001")
    show = browser.get("/invoicing/documents/#{invoice_id}").html
    show.should contain("Créer un avoir")
    show.should contain("Issu du devis D-#{year}-0001")
    show.should contain("pd-mentions")

    pdf = browser.get("/invoicing/documents/#{invoice_id}/pdf")
    pdf.status.should eq(200)
    pdf.content_type.should eq("application/pdf")
    pdf.content.should start_with("%PDF-")
    pdf.headers["Content-Disposition"].should contain("F-#{year}-0001")

    preview = browser.get("/invoicing/documents/#{invoice_id}/preview").html
    preview.should contain(%(class="pd-paper"))
    preview.should contain("F-#{year}-0001")
    preview.should contain("Atelier Morel")
    preview.should contain("960,00")

    list = browser.get("/invoicing/documents?kind=invoice").html
    list.should contain(%(href="/invoicing/documents/#{invoice_id}">F-#{year}-0001</a>))
    list.should contain(%(aria-current="page">Facture</a>))

    credit = browser.post("/invoicing/documents/#{invoice_id}/transform?kind=credit_note")
    credit.status.should eq(302)
    browser.follow(credit).html.should contain("Brouillon créé : Avoir.")
  end

  it "enregistre un règlement quand la Comptabilité est inactive, et renvoie au lettrage sinon" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    invoice = issued_invoice(customer)
    with_accounting = browser.get("/invoicing/payments").html
    with_accounting.should contain("le règlement est enregistré par le lettrage")
    with_accounting.should contain(invoice.number || "")

    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
    form = browser.get("/invoicing/documents/#{invoice.id}/payment").html
    form.should contain(%(name="amount"))
    form.should contain("96")
    response = browser.post("/invoicing/documents/#{invoice.id}/payment",
      {"amount" => "96", "paid_on" => "2026-02-01", "method" => "transfer", "reference" => "VIR-1"})
    response.status.should eq(302)
    browser.follow(response).html.should contain("Règlement de 96,00 enregistré.")
    Inv.document(Books.system, invoice.id).effective_status.should eq("paid")
    browser.get("/invoicing/payments").html.should contain("Aucune facture à encaisser.")
  end

  it "propose les relances des factures échues, puis les écarte" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    invoice = issued_invoice(customer)
    browser.get("/invoicing/reminders").html.should contain("Aucune relance à envoyer.")
    proposed = browser.post("/invoicing/reminders/propose")
    browser.follow(proposed).html.should contain("1 relance proposée.")
    page = browser.get("/invoicing/reminders?customer=#{customer.id}").html
    page.should contain(invoice.number || "")
    page.should contain("Atelier Morel")
    reminder = Inv.reminders(Books.system).first
    dismissed = browser.post("/invoicing/reminders/#{reminder.id}/dismiss")
    browser.follow(dismissed).html.should contain("Relance de la facture #{invoice.number} écartée.")
  end

  it "transmet au comptable : CSV du journal des ventes" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    issued_invoice(customer)
    browser.get("/invoicing/export").html.should contain("Journal des ventes et des encaissements (CSV)")
    csv = browser.get("/invoicing/export?from=2026-01-01&to=2026-01-31&format=csv")
    csv.status.should eq(200)
    csv.headers["Content-Disposition"].should contain("attachment")
  end

  it "répond 404 quand la Facturation est inactive, 403 sans droit d'écriture" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "INVOICING")
    browser.get("/invoicing/documents").status.should eq(404)
    browser.get("/invoicing/invoices/new").status.should eq(404)

    Partiduo::Api::Modules.activate(Books.system, "INVOICING")
    profile = PartiduoUi::Accounts.profile("Lecteur factures", ["invoicing.invoice.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    bob.get("/invoicing/documents").status.should eq(200)
    bob.get("/invoicing/documents").html.should_not contain("Nouvelle facture</span>")
    bob.get("/invoicing/invoices/new").status.should eq(403)
  end
end

describe "Tableau de bord (ADR-005 D5)" do
  it "assemble les tuiles des modules actifs et « À traiter »" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    Books.sale(customer.code, "100", "2026-01-10", "2026-01-20")
    issued_invoice(customer)
    page = browser.get("/").html
    page.should contain("Clients à encaisser")
    page.should contain("Fournisseurs à payer")
    page.should contain("Devis en attente de réponse")
    page.should contain("Dernières écritures")
    page.should contain("Dernières factures")
    page.should contain("À traiter")
    page.should contain("échus chez les clients")
    page.should contain("1 facture en retard")
    page.should contain(%(href="/accounting/entries/purchase"))
    page.should contain(%(href="/invoicing/invoices/new"))

    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
    alone = browser.get("/").html
    alone.should_not contain("Clients à encaisser")
    alone.should contain("Factures à encaisser")
    alone.should_not contain("Dernières écritures")
  end
end
