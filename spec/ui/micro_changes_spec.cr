# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# D-MIC2-001, D-MIC2-005 : registres de la micro-entreprise groupés par
# période de déclaration URSSAF ; ligne d'une période ouverte : Modifier et
# Supprimer (confirmation) ; période déclarée : cadenas, « déclarée le … »
# et « Contre-passer ». Mode simplifié compris, téléphone compris (cibles
# de 44 px), fr, en, nl. Tout par `Partiduo::Api`.

private alias Micro = Partiduo::Api::Micro
private alias Books = PartiduoUi::Books

# Dossier micro-entreprise (Micro et Facturation actifs), administrateur
# connecté — en mode simplifié, comme tout utilisateur de la société.
private def change_books : PartiduoUi::Browser
  browser = Books.admin
  Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
  Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  Partiduo::Api::Modules.activate(Books.system, "MICRO").success?.should be_true
  Micro.load_defaults(Books.system)
  browser
end

private def change_nature(code : String) : Micro::NatureView
  Micro.natures(Books.system).find! { |item| item.code == code }
end

private def change_receipt(day : String, amount : String, party : String = "Atelier Morel") : Micro::LineView
  input = Micro::ReceiptInput.new(date: Books.date(day), nature_id: change_nature("SERVICE").id, amount: Books.d(amount),
    method: "transfer", party_name: party)
  Micro.record_receipt(Books.system, input).value!
end

private def declare_first_quarter : Nil
  Micro.mark_declared(Books.system, Micro::DeclarationInput.new(Books.date("2026-01-01"), Books.date("2026-04-10"))).value!
end

describe "Registres de la micro-entreprise — modification en période ouverte (D-MIC2-001)" do
  it "groupe la liste par trimestre : déclaré (cadenas, contre-passer), ouvert (modifier, supprimer)" do
    browser = change_books
    declared = change_receipt("2026-02-10", "100", "Client déclaré")
    open = change_receipt("2026-05-10", "50", "Client ouvert")
    declare_first_quarter
    page = browser.get("/micro/receipts?year=2026").html
    page.should contain("pd-simple")
    page.should contain(%(<th scope="rowgroup" colspan="7">))
    page.should contain("1er trimestre 2026")
    page.should contain("déclarée le 10/04/2026")
    page.should contain("2e trimestre 2026")
    page.should contain("non déclarée, modifiable")
    # Ordre des groupes : le plus récent d'abord, chaque ligne sous le sien.
    page.index!("2e trimestre 2026").should be < page.index!("Client ouvert")
    page.index!("Client ouvert").should be < page.index!("1er trimestre 2026")
    page.index!("1er trimestre 2026").should be < page.index!("Client déclaré")
    # Ligne ouverte : modifier, supprimer (confirmation), noms accessibles.
    page.should contain(%(href="/micro/receipts/#{open.id}/edit" aria-label="Modifier #{open.number}"))
    page.should contain(%(action="/micro/receipts/#{open.id}/delete"))
    page.should contain(%(aria-label="Supprimer #{open.number}"))
    page.should contain("data-pd-confirm=\"Supprimer cette ligne ?")
    # Ligne déclarée : cadenas, texte pour les lecteurs d'écran, contre-passer.
    page.should contain("Période close, ligne intangible :")
    page.should contain(%(aria-label="Contre-passer #{declared.number}"))
    page.should_not contain(%(href="/micro/receipts/#{declared.id}/edit"))
    page.should_not contain(%(action="/micro/receipts/#{declared.id}/delete"))
    # Téléphone : boutons de ligne à 44 px, colonne des actions visible.
    page.should contain("pd-row-button")
    page.should_not contain("missing translation")
  end

  it "modifie une ligne d'une période ouverte par le formulaire de saisie prérempli" do
    browser = change_books
    line = change_receipt("2026-05-10", "50")
    form = browser.get("/micro/receipts/#{line.id}/edit")
    form.status.should eq(200)
    html = form.html
    html.should contain("Modifier : Recette #{line.number}")
    html.should contain(%(value="50,00"))
    html.should contain(%(value="2026-05-10"))
    html.should contain(%(action="/micro/receipts/#{line.id}/edit"))
    html.should_not contain("Enregistrer et en saisir une autre")
    html.should_not contain("missing translation")

    refused = browser.post("/micro/receipts/#{line.id}/edit", {"amount" => "", "date" => "2026-05-10",
                                                               "nature_id" => change_nature("SERVICE").id.to_s, "method" => "cash"})
    refused.status.should eq(422)
    refused.html.should contain("Ce champ est obligatoire.")

    saved = browser.post("/micro/receipts/#{line.id}/edit", {"amount" => "65,40", "date" => "2026-05-12",
                                                             "nature_id" => change_nature("SALE").id.to_s, "method" => "cash",
                                                             "party_name" => "Atelier Morel"})
    saved.status.should eq(302)
    saved.headers["Location"].should eq("/micro/receipts/#{line.id}")
    browser.follow(saved).html.should contain("Ligne #{line.number} modifiée.")
    changed = Micro.receipt(Books.system, line.id)
    {changed.amount, changed.date, changed.nature_code, changed.method}.should eq({Books.d("65.4"), Books.date("2026-05-12"), "SALE", "cash"})

    # Nouvelle date dans un trimestre déclaré : refus du contrat, à l'écran.
    declare_first_quarter
    moved = browser.post("/micro/receipts/#{line.id}/edit", {"amount" => "65,40", "date" => "2026-03-01",
                                                             "nature_id" => change_nature("SALE").id.to_s, "method" => "cash"})
    moved.status.should eq(422)
    moved.html.should contain("déjà déclarée")
  end

  it "supprime une ligne d'une période ouverte, refuse celle d'une période déclarée" do
    browser = change_books
    declared = change_receipt("2026-02-10", "100")
    open = change_receipt("2026-05-10", "50")
    declare_first_quarter
    deleted = browser.post("/micro/receipts/#{open.id}/delete")
    deleted.status.should eq(302)
    deleted.headers["Location"].should eq("/micro/receipts?year=2026")
    browser.follow(deleted).html.should contain("Ligne #{open.number} supprimée.")
    Micro.receipts(Books.system).map(&.id).should eq([declared.id])

    refused = browser.post("/micro/receipts/#{declared.id}/delete")
    refused.headers["Location"].should eq("/micro/receipts/#{declared.id}")
    browser.follow(refused).html.should contain("Période déjà déclarée à l'URSSAF")
    edit = browser.get("/micro/receipts/#{declared.id}/edit")
    edit.headers["Location"].should eq("/micro/receipts/#{declared.id}")
    browser.follow(edit).html.should contain("Période déjà déclarée à l'URSSAF")
    Micro.receipts(Books.system).size.should eq(1)

    # Contre-passation de la ligne déclarée : datée du jour, période suivante.
    browser.post("/micro/receipts/#{declared.id}/reverse").status.should eq(302)
    reversal_id = Micro.receipt(Books.system, declared.id).reversed_by_id || raise "recette non contre-passée"
    reversal = Micro.receipt(Books.system, reversal_id)
    reversal.date.should eq(Partiduo::Api::Core.today)
    reversal.locked.should be_false
    reversal.deletable?.should be_true
  end

  it "modifie et supprime un achat de la même façon" do
    browser = change_books
    input = Micro::PurchaseInput.new(date: Books.date("2026-05-10"), nature_id: change_nature("SUPPLIES").id,
      amount: Books.d("30"), method: "card", party_name: "Papeterie Centrale")
    line = Micro.record_purchase(Books.system, input).value!
    browser.get("/micro/purchases?year=2026").html.should contain(%(aria-label="Modifier #{line.number}"))
    browser.post("/micro/purchases/#{line.id}/edit", {"amount" => "31", "date" => "2026-05-10",
                                                      "nature_id" => change_nature("SUPPLIES").id.to_s, "method" => "card"}).status.should eq(302)
    Micro.purchase(Books.system, line.id).amount.should eq(Books.d("31"))
    browser.post("/micro/purchases/#{line.id}/delete").status.should eq(302)
    Micro.purchases(Books.system).should be_empty
  end

  it "ne propose rien au lecteur et lui refuse modification et suppression" do
    change_books
    line = change_receipt("2026-05-10", "50")
    profile = PartiduoUi::Accounts.profile("Lecture", ["micro.register.read"])
    PartiduoUi::Accounts.create("lecture@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("lecture@example.com")
    page = reader.get("/micro/receipts?year=2026").html
    page.should_not contain("/edit")
    page.should_not contain("/delete")
    reader.get("/micro/receipts/#{line.id}").html.should_not contain("Modifier")
    reader.get("/micro/receipts/#{line.id}/edit").status.should eq(403)
    reader.post("/micro/receipts/#{line.id}/edit", {"amount" => "1"}).status.should eq(403)
    reader.post("/micro/receipts/#{line.id}/delete").status.should eq(403)
    Micro.receipt(Books.system, line.id).amount.should eq(Books.d("50"))
  end

  it "traduit périodes et actions en anglais et en néerlandais" do
    browser = change_books
    change_receipt("2026-02-10", "100")
    change_receipt("2026-05-10", "50")
    declare_first_quarter
    {"en" => {"Q1 2026", "declared on", "Reverse", "Edit"},
     "nl" => {"1e kwartaal 2026", "aangegeven op", "Tegenboeken", "Wijzigen"}}.each do |locale, words|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      page = browser.get("/micro/receipts?year=2026").html
      words.each { |word| page.should contain(word) }
      page.should_not contain("missing translation")
    end
  end
end
