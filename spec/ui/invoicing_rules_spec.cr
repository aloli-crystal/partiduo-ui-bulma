# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 2F — écrans de facturation, cas limites : validation refusée
# (échéance passée), messages accordés à la nature du document, suppression
# d'un brouillon et refus pour un document émis, acompte sans pourcentage,
# décision sur un devis, règlement supérieur au solde, documents inconnus.

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books

private def product : Partiduo::Api::Cards::CardView
  Partiduo::Api::Cards.card_by_code(Books.system, "CONSEIL") || begin
    rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
    input = Partiduo::Api::Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id,
      name: "Conseil (heure)", code: "CONSEIL", unit_code: "HUR", sale_price: Books.d("80"), vat_rate_id: rate.id)
    Partiduo::Api::Cards.create_card(Books.system, input).value!
  end
end

private def draft(customer : Partiduo::Api::Cards::CardView, kind : String = "invoice", **options) : Inv::DocumentView
  input = Inv::DocumentInput.new(kind: kind, customer_card_id: customer.id,
    lines: [Inv::LineInput.new(item_card_id: product.id, quantity: Books.d("1"))]).copy_with(**options)
  Inv.create_document(Books.system, input).value!
end

private def issued(customer : Partiduo::Api::Cards::CardView, kind : String = "invoice", **options) : Inv::DocumentView
  Inv.issue(Books.system, draft(customer, kind, **options).id).value!
end

describe "Devis et factures — cas limites (lot 2F)" do
  it "refuse la validation d'une facture échue avant sa date, sans lui donner de numéro" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    document = draft(customer, due_date: Books.date("2020-01-01"))
    response = browser.post("/invoicing/documents/#{document.id}/issue")
    response.status.should eq(302)
    page = browser.follow(response).html
    page.should contain("is-danger")
    page.should contain(I18n.t("invoicing.errors.document.due_date.before_issue"))
    Inv.document(Books.system, document.id).number.should be_nil
  end

  it "accorde les messages à la nature du document (facture : féminin)" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    quote = issued(customer, "quote")
    transformed = browser.post("/invoicing/documents/#{quote.id}/transform?kind=invoice")
    edit = browser.follow(transformed).html
    edit.should_not contain("Facture créé ")
    edit.should contain(I18n.t("ui.invoicing.transformed", kind: "Facture"))

    invoice_id = PartiduoUi::Reference.id_from(transformed.headers["Location"].sub("/edit", ""))
    shown = browser.follow(browser.post("/invoicing/documents/#{invoice_id}/issue")).html
    number = Inv.document(Books.system, invoice_id).number || raise "facture non émise"
    shown.should contain(I18n.t("ui.invoicing.issued", title: "Facture #{number}"))
    shown.should_not contain("Facture #{number} validé.")
  end

  it "supprime un brouillon, mais pas un document émis" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    document = draft(customer)
    deleted = browser.post("/invoicing/documents/#{document.id}/delete")
    deleted.headers["Location"].should eq("/invoicing/documents")
    expect_raises(Partiduo::Api::NotFound) { Inv.document(Books.system, document.id) }

    invoice = issued(customer)
    refused = browser.post("/invoicing/documents/#{invoice.id}/delete")
    refused.headers["Location"].should eq("/invoicing/documents/#{invoice.id}")
    browser.follow(refused).html.should contain("is-danger")
    Inv.document(Books.system, invoice.id).number.should eq(invoice.number)
  end

  it "demande le pourcentage d'un acompte et refuse une transformation interdite" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    order = issued(customer, "order")
    missing = browser.post("/invoicing/documents/#{order.id}/transform", {"kind" => "deposit_invoice", "deposit_percent" => "abc"})
    browser.follow(missing).html.should contain(I18n.t("ui.invoicing.deposit_percent_required"))
    deposit = browser.post("/invoicing/documents/#{order.id}/transform", {"kind" => "deposit_invoice", "deposit_percent" => "30"})
    deposit.headers["Location"].should end_with("/edit")
    Inv.documents(Books.system, Inv::DocumentQuery.new(kind: "deposit_invoice")).size.should eq(1)

    invoice = issued(customer)
    wrong = browser.post("/invoicing/documents/#{invoice.id}/transform?kind=order")
    browser.follow(wrong).html.should contain("is-danger")
    # Le message d'erreur reprend la saisie : il est échappé.
    hostile = browser.post("/invoicing/documents/#{invoice.id}/transform", {"kind" => "<b>x</b>"})
    raw = browser.follow(hostile).content
    raw.should contain("is-danger")
    raw.should_not contain("<b>x</b>")
    Inv.documents(Books.system, Inv::DocumentQuery.new(kind: "order")).size.should eq(1)
  end

  it "marque un devis refusé, puis n'admet plus de décision" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    quote = issued(customer, "quote", validity_date: Books.date("2099-01-01"))
    browser.get("/invoicing/documents/#{quote.id}").html.should contain("/invoicing/documents/#{quote.id}/decide")
    refused = browser.post("/invoicing/documents/#{quote.id}/decide", {"decision" => "refused"})
    browser.follow(refused).html.should contain(I18n.t("ui.invoicing.decided.refused"))
    Inv.document(Books.system, quote.id).status.should eq("refused")
    browser.get("/invoicing/documents/#{quote.id}").html.should_not contain("/invoicing/documents/#{quote.id}/decide")
    again = browser.post("/invoicing/documents/#{quote.id}/decide", {"decision" => "accepted"})
    browser.follow(again).html.should contain("is-danger")
  end

  it "refuse un règlement supérieur au solde (Comptabilité inactive) et une date illisible" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    invoice = issued(customer) # 96,00 TTC
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
    over = browser.post("/invoicing/documents/#{invoice.id}/payment",
      {"amount" => "100", "paid_on" => "2026-09-20", "method" => "transfer", "reference" => ""})
    over.status.should_not eq(302)
    over.html.should contain("is-danger")
    bad_date = browser.post("/invoicing/documents/#{invoice.id}/payment",
      {"amount" => "10", "paid_on" => "32/13", "method" => "transfer", "reference" => ""})
    bad_date.html.should contain(I18n.t("ui.forms.invalid_date"))
    Inv.payments(Books.system, invoice.id).should be_empty
  end

  it "répond 404 pour un document inconnu, 403 à la validation sans le droit" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    browser.get("/invoicing/documents/987654").status.should eq(404)
    browser.get("/invoicing/documents/987654/pdf").status.should eq(404)
    document = draft(customer)
    profile = PartiduoUi::Accounts.profile("Rédaction", ["invoicing.invoice.read", "invoicing.invoice.write"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    bob.get("/invoicing/documents/#{document.id}").html.should_not contain("/invoicing/documents/#{document.id}/issue")
    bob.post("/invoicing/documents/#{document.id}/issue").status.should eq(403)
    Inv.document(Books.system, document.id).number.should be_nil
  end
end
