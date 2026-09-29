# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Conditions de paiement et adresse de livraison dans l'édition d'une facture
# (BLOCAGES B-FIN-001, DECISIONS D-R5-003, D-R5-004).

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books
private alias Cards = Partiduo::Api::Cards

private def customer_with_deliveries : Cards::CardView
  category = PartiduoUi::Reference.category("CUSTOMER")
  input = Cards::CardInput.new(category_id: category.id, name: "Atelier Morel", code: "CLI-MOREL",
    address: Cards::AddressInput.new(line1: "3 rue du Port", postcode: "44100", city: "Nantes", country_code: "FR"),
    delivery_addresses: [
      Cards::AddressInput.new(label: "Atelier", line1: "Zone artisanale, lot 7", postcode: "44800", city: "Saint-Herblain", country_code: "FR"),
      Cards::AddressInput.new(label: "Dépôt", line1: "Quai de la Fosse 2", postcode: "44000", city: "Nantes", country_code: "FR"),
    ])
  Cards.create_card(Books.system, input).value!
end

private def item : Cards::CardView
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  input = Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil (heure)",
    code: "CONSEIL", unit_code: "HUR", sale_price: Books.d("80"), vat_rate_id: rate.id)
  Cards.create_card(Books.system, input).value!
end

private def invoice_values(extra = {} of String => String) : Hash(String, String)
  {"kind" => "invoice", "customer" => "CLI-MOREL", "issue_date" => "", "delivery_date" => "", "due_date" => "",
   "operation_category" => "services", "global_discount" => "", "buyer_reference" => "", "order_reference" => "",
   "notes" => "", "line-0-item" => "CONSEIL", "line-0-description" => "", "line-0-quantity" => "2", "line-0-unit" => "",
   "line-0-unit_price" => "", "line-0-discount" => "", "line-0-vat_rate_id" => ""}.merge(extra)
end

private def created(browser, values) : Inv::DocumentView
  response = browser.post("/invoicing/documents/new", values)
  response.status.should eq(302)
  Inv.document(Books.system, PartiduoUi::Reference.id_from(response.headers["Location"]))
end

describe "Édition d'une facture : conditions de paiement et adresse de livraison" do
  it "propose les conditions de la maquette et les enregistre sur le document" do
    browser = Books.admin
    customer_with_deliveries
    item
    form = browser.get("/invoicing/documents/new?kind=invoice").html
    form.should contain(%(<select id="pd-d-terms" name="payment_terms"))
    form.should contain(%(<option value="end_of_month:45">45 jours fin de mois</option>))
    form.should contain(%(<option value="on_receipt">À réception</option>))
    form.should contain("Paramètres (30 jours)")
    document = created(browser, invoice_values({"payment_terms" => "end_of_month:45"}))
    {document.payment_terms, document.payment_terms_days}.should eq({"end_of_month", 45})
    document.mentions.map(&.code).should contain("payment.terms.end_of_month")
    edit = browser.get("/invoicing/documents/#{document.id}/edit").html
    edit.should contain(%(<option value="end_of_month:45" selected>))
    receipt = created(browser, invoice_values({"payment_terms" => "on_receipt"}))
    {receipt.payment_terms, receipt.payment_terms_days}.should eq({"on_receipt", nil})
    refused = browser.post("/invoicing/documents/new", invoice_values({"payment_terms" => "net:abc"}))
    refused.status.should eq(422)
    refused.html.should contain("Conditions de paiement non reconnues")
    browser.get("/invoicing/documents/new?kind=delivery_note").html.should_not contain(%(name="payment_terms"))
  end

  it "choisit l'adresse de livraison parmi celles de la fiche, aucune, ou une autre" do
    browser = Books.admin
    customer_with_deliveries
    item
    by_default = created(browser, invoice_values)
    by_default.delivery_address.try(&.city).should eq("Saint-Herblain")
    depot = created(browser, invoice_values({"delivery" => "card:1"}))
    depot.delivery_address.try(&.line1).should eq("Quai de la Fosse 2")
    none = created(browser, invoice_values({"delivery" => "none"}))
    none.delivery_address.should be_nil
    other = created(browser, invoice_values({"delivery" => "other", "delivery_line1" => "Rue des Halles 4",
                                             "delivery_postcode" => "49000", "delivery_city" => "Angers", "delivery_country" => "fr"}))
    address = other.delivery_address || raise "adresse absente"
    {address.line1, address.city, address.country_code}.should eq({"Rue des Halles 4", "Angers", "FR"})
    incomplete = browser.post("/invoicing/documents/new", invoice_values({"delivery" => "other", "delivery_line1" => "Rue"}))
    incomplete.status.should eq(422)
    incomplete.html.should contain("Indiquez au moins l'adresse et la ville")

    # Relecture d'un brouillon : l'adresse enregistrée est reconnue.
    browser.get("/invoicing/documents/#{depot.id}/edit").html.should contain(%(<option value="card:1" selected>))
    browser.get("/invoicing/documents/#{none.id}/edit").html.should contain(%(<option value="none" selected>))
    edit_other = browser.get("/invoicing/documents/#{other.id}/edit").html
    edit_other.should contain(%(<option value="other" selected>))
    edit_other.should contain(%(value="Rue des Halles 4"))
  end

  it "recharge les adresses du client saisi (HTMX)" do
    browser = Books.admin
    customer_with_deliveries
    fragment = browser.get("/invoicing/documents/delivery?customer=CLI-MOREL&delivery=card:1").html
    fragment.should contain(%(id="pd-d-delivery-box"))
    fragment.should contain("Dépôt, Quai de la Fosse 2, 44000 Nantes, FR")
    fragment.should contain(%(<option value="" selected>))
    browser.get("/invoicing/documents/delivery?customer=INCONNU").html.should_not contain("card:0")
  end
end
