# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Fournisseur personne physique (DAS2) dans l'interface : nature, nom,
# prénoms et date de naissance sur la fiche. DECISIONS D-R5-001.

private alias Books = PartiduoUi::Books

describe "Fournisseur personne physique (fiche, interface)" do
  it "saisit la nature et l'identité d'un fournisseur personne physique, puis les affiche" do
    browser = Books.admin
    suppliers = PartiduoUi::Reference.category("SUPPLIER")
    form = browser.get("/cards/new?category=#{suppliers.id}").html
    form.should contain(%(name="supplier_nature"))
    form.should contain("Personne physique")
    form.should contain(%(name="birth_date"))
    customers = PartiduoUi::Reference.category("CUSTOMER")
    browser.get("/cards/new?category=#{customers.id}").html.should_not contain(%(name="supplier_nature"))

    response = browser.post("/cards/new", {"category_id" => suppliers.id.to_s, "name" => "", "enabled" => "1",
                                           "supplier_nature" => "individual", "last_name" => "DURAND",
                                           "first_names" => "Paul", "birth_date" => "1971-04-02"})
    response.status.should eq(302)
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    card = Partiduo::Api::Cards.card(Books.system, id)
    {card.name, card.supplier_nature, card.last_name, card.first_names, card.birth_date}
      .should eq({"DURAND Paul", "individual", "DURAND", "Paul", Time.utc(1971, 4, 2)})
    page = browser.follow(response).html
    page.should contain("Nature du fournisseur")
    page.should contain("Date de naissance")
    page.should contain("02/04/1971")

    edit = browser.get("/cards/#{id}/edit").html
    edit.should contain(%(value="1971-04-02"))
    browser.post("/cards/#{id}/edit", {"category_id" => suppliers.id.to_s, "name" => "Durand SARL", "enabled" => "1",
                                       "supplier_nature" => "business"}).status.should eq(302)
    updated = Partiduo::Api::Cards.card(Books.system, id)
    {updated.supplier_nature, updated.last_name, updated.birth_date}.should eq({"business", "", nil})
  end

  it "rend les erreurs d'une personne physique incomplète ou d'une date illisible, champ par champ" do
    browser = Books.admin
    suppliers = PartiduoUi::Reference.category("SUPPLIER")
    refused = browser.post("/cards/new", {"category_id" => suppliers.id.to_s, "name" => "X", "enabled" => "1",
                                          "supplier_nature" => "individual", "birth_date" => "pas une date"})
    refused.status.should eq(422)
    html = refused.html
    html.should contain("Indiquez une date valide.")
    html.should contain(%(value="pas une date"))
    missing = browser.post("/cards/new", {"category_id" => suppliers.id.to_s, "name" => "X", "enabled" => "1",
                                          "supplier_nature" => "individual"}).html
    missing.should contain("Le nom de la personne physique est obligatoire.")
    missing.should contain("Les prénoms de la personne physique sont obligatoires.")
    missing.should contain(%(aria-invalid="true"))
  end
end
