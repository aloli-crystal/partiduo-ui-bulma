# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Bons à facturer, facture récapitulative, fin de mois, réglage client et
# encours maximum HT (DECISIONS D-INV2-001 à D-INV2-010).

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books
private alias Cards = Partiduo::Api::Cards

private def customer(name : String, code : String, email : String = "") : Cards::CardView
  category = PartiduoUi::Reference.category("CUSTOMER")
  input = Cards::CardInput.new(category_id: category.id, name: name, code: code, email: email, siren: "443061841",
    address: Cards::AddressInput.new(line1: "3 rue du Port", postcode: "44100", city: "Nantes", country_code: "FR"))
  Cards.create_card(Books.system, input).value!
end

private def item : Cards::CardView
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  input = Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil (heure)",
    code: "CONSEIL", unit_code: "HUR", sale_price: Books.d("80"), vat_rate_id: rate.id)
  Cards.create_card(Books.system, input).value!
end

# Bon de livraison émis le `day` : `hours` heures de conseil (80 € HT l'heure).
private def delivery_note(client : Cards::CardView, article : Cards::CardView, day : String,
                          hours : String = "1", issue : Bool = true) : Inv::DocumentView
  input = Inv::DocumentInput.new(kind: "delivery_note", customer_card_id: client.id,
    lines: [Inv::LineInput.new(kind: "item", item_card_id: article.id, quantity: Books.d(hours))])
  draft = Inv.create_document(Books.system, input).value!
  return draft unless issue
  Inv.issue(Books.system, draft.id, Inv::IssueInput.new(issue_date: Books.date(day))).value!
end

private def card_path(id : Int64) : String
  Marten.routes.reverse("cards:show", id: id)
end

describe "Bons à facturer (D-INV2-010)" do
  it "liste les bons émis non facturés et en fait une facture récapitulative" do
    browser = Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    other = customer("Menuiserie Roux", "CLI-ROUX")
    article = item
    first = delivery_note(client, article, "2026-09-03")
    second = delivery_note(client, article, "2026-09-10", "2")
    third = delivery_note(other, article, "2026-09-11")

    page = browser.get("/invoicing/to-invoice").html
    [first, second, third].each { |note| page.should contain(note.number.to_s) }
    page.should contain("Facturer ces bons")
    page.should contain("Encours HT / plafond")
    page.should contain(%(<input type="checkbox" name="note" value="#{first.id}"))
    filtered = browser.get("/invoicing/to-invoice?customer=#{other.id}").html
    filtered.should contain(third.number.to_s)
    filtered.should_not contain(first.number.to_s)

    refused = browser.perform_raw("/invoicing/to-invoice", "note=#{first.id}&note=#{third.id}")
    refused.status.should eq(422)
    refused.html.should contain("plusieurs clients")

    response = browser.perform_raw("/invoicing/to-invoice", "note=#{first.id}&note=#{second.id}")
    response.status.should eq(302)
    invoice = Inv.document(Books.system, PartiduoUi::Reference.id_from(response.headers["Location"]))
    invoice.delivery_notes.map(&.id).should eq([first.id, second.id])
    shown = browser.follow(response).html
    shown.should contain("Bon de livraison #{first.number} du 03/09/2026")
    shown.should contain("Bon de livraison #{second.number} · livré le 10/09/2026")
    edit = browser.get("/invoicing/documents/#{invoice.id}/edit").html
    edit.should contain(%(name="line-1-delivery_note" value="#{first.id}"))
    browser.get("/invoicing/to-invoice").html.should contain("Repris dans un brouillon de facture")

    browser.post("/invoicing/documents/#{invoice.id}/issue").status.should eq(302)
    browser.get("/invoicing/documents/#{invoice.id}").html.should contain("Livraisons du 03/09/2026 au 10/09/2026")
    note_page = browser.get("/invoicing/documents/#{first.id}").html
    note_page.should contain("Facturé")
    note_page.should_not contain("Transformer en facture")
    note_page.should contain(Inv.document(Books.system, invoice.id).number.to_s)
    browser.get("/invoicing/to-invoice").html.should_not contain(%(name="note" value="#{first.id}"))
  end

  it "règle le rythme et l'encours maximum HT sur la fiche client, jauge accessible" do
    browser = Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    article = item
    delivery_note(client, article, "2026-09-03", "11") # 880 € HT
    form = browser.get("/invoicing/customers/#{client.id}/billing").html
    form.should contain("Encours maximum HT")
    form.should contain("Récapitulative mensuelle")
    saved = browser.post("/invoicing/customers/#{client.id}/billing", {"billing_rhythm" => "monthly", "credit_limit" => "1000"})
    saved.status.should eq(302)
    saved.headers["Location"].should eq(card_path(client.id))
    refused = browser.post("/invoicing/customers/#{client.id}/billing", {"billing_rhythm" => "monthly", "credit_limit" => "-5"})
    refused.status.should eq(422)

    card = browser.get(card_path(client.id)).html
    card.should contain("Facturation")
    card.should contain("Récapitulative mensuelle")
    card.should contain("1\u202F000,00 EUR")
    card.should contain(%(role="img" aria-label="Encours HT : 880,00 sur 1\u202F000,00 EUR, Sous le plafond"))
    card.should contain("Facturer le mois de ce client")
    # Au-delà de 90 % : « À traiter » et l'état écrit en toutes lettres.
    delivery_note(client, article, "2026-09-04", "1")
    browser.get(card_path(client.id)).html.should contain("Proche du plafond (96\u202F%)")
    browser.get("/").html.should contain("1 client proche de son encours maximum HT")
  end

  it "refuse l'émission au-delà du plafond et accepte la dérogation motivée, tracée" do
    browser = Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    article = item
    Inv.update_customer_billing(Books.system, client.id, Inv::CustomerBillingInput.new("per_delivery", Books.d("100"))).value!
    draft = delivery_note(client, article, "2026-09-03", "2", issue: false)
    page = browser.get("/invoicing/documents/#{draft.id}").html
    page.should contain("Encours maximum dépassé.")
    page.should contain("ce document ajoute 160,00 EUR pour un plafond de 100,00 EUR (dépassement : 60,00 EUR)")
    page.should contain(%(name="credit_override_reason"))
    browser.post("/invoicing/documents/#{draft.id}/issue")
    Inv.document(Books.system, draft.id).draft?.should be_true
    browser.post("/invoicing/documents/#{draft.id}/issue", {"credit_override_reason" => "Accord du gérant"})
    Inv.document(Books.system, draft.id).draft?.should be_false
    browser.get("/invoicing/documents/#{draft.id}").html.should contain("Dérogation à l'encours maximum")
  end

  it "prépare le mois, le propose dans « À traiter », émet et envoie d'un clic" do
    browser = Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    article = item
    Inv.update_customer_billing(Books.system, client.id, Inv::CustomerBillingInput.new("monthly")).value!
    delivery_note(client, article, "2026-09-03")
    delivery_note(client, article, "2026-09-10")
    browser.post("/invoicing/to-invoice/month", {"month" => "2026-09"}).status.should eq(302)
    proposals = Inv.monthly_proposals(Books.system)
    proposals.size.should eq(1)
    page = browser.get("/invoicing/to-invoice").html
    page.should contain("Factures de fin de mois proposées")
    page.should contain("Tout émettre et envoyer")
    browser.get("/").html.should contain("1 facture récapitulative du mois à émettre")
    invoice_id = proposals.first.invoice_id || raise "sans facture"
    browser.post("/invoicing/documents/#{invoice_id}/issue-send").status.should eq(302)
    Inv.document(Books.system, invoice_id).draft?.should be_false
    Inv.monthly_proposals(Books.system).should be_empty
  end

  it "règle la facturation mensuelle dans les paramètres de la Facturation" do
    browser = Books.admin
    page = browser.get("/invoicing/settings").html
    page.should contain("Facturation mensuelle des bons de livraison")
    page.should contain(%(<option value="auto_send">Émettre et envoyer automatiquement</option>))
    input = Inv.settings(Books.system).to_input.copy_with(monthly_billing_mode: "auto_send")
    Inv.update_settings(Books.system, input).value!
    browser.get("/invoicing/settings").html.should contain(%(<option value="auto_send" selected>))
  end

  it "réserve le réglage client aux paramètres de la Facturation" do
    Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    profile = PartiduoUi::Accounts.profile("Vendeur", %w[invoicing.invoice.read invoicing.invoice.write cards.card.read])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    seller = PartiduoUi::Accounts.signed_in("bob@example.com")
    seller.get("/invoicing/customers/#{client.id}/billing").status.should eq(403)
    card = seller.get(card_path(client.id)).html
    card.should contain("Facturation")
    card.should_not contain("/invoicing/customers/#{client.id}/billing")
  end
end
