# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Clôture du lot G : écrans du paramétrage de la micro-entreprise
# (ADR-007 D1, D2) — natures, paramètres datés, natures des articles,
# bascules guidées vers la TVA et vers le régime réel, republication vers la
# Comptabilité, comptes de la Comptabilité, récapitulatif des achats et TVA
# déductible. Tout par `Partiduo::Api`.

private alias Micro = Partiduo::Api::Micro
private alias Books = PartiduoUi::Books

private def settings_books(accounting : Bool = false) : PartiduoUi::Browser
  browser = Books.admin
  unless accounting
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  end
  Partiduo::Api::Modules.activate(Books.system, "MICRO").success?.should be_true
  Micro.load_defaults(Books.system)
  browser
end

private def settings_nature(code : String) : Micro::NatureView
  Micro.natures(Books.system).find! { |item| item.code == code }
end

describe "Paramétrage de la micro-entreprise (ADR-007 D1, D2)" do
  it "relie depuis les paramètres les natures, taux, articles et bascules" do
    browser = settings_books
    page = browser.get("/micro/settings").html
    %w[/micro/natures /micro/parameters /micro/items /micro/switch/vat /micro/switch/real].each do |path|
      page.should contain(%(href="#{path}"))
    end
    # Comptabilité inactive : ni republication, ni comptes.
    page.should_not contain("/micro/republish")
    page.should_not contain("missing translation")
  end

  it "crée une nature, puis en change le libellé" do
    browser = settings_books
    browser.get("/micro/natures").html.should contain("SERVICE")
    created = browser.post("/micro/natures", {"code" => "cours", "label" => "Cours particuliers", "kind" => "receipt",
                                              "category" => "bnc", "enabled" => "1"})
    created.headers["Location"].should eq("/micro/natures")
    nature = settings_nature("COURS")
    nature.category.should eq("bnc")
    refused = browser.post("/micro/natures", {"code" => "COURS", "label" => "Doublon", "kind" => "receipt", "category" => "bnc"})
    refused.status.should eq(422)
    refused.html.should contain("Code déjà pris")
    browser.get("/micro/natures/#{nature.id}").status.should eq(200)
    browser.post("/micro/natures/#{nature.id}", {"code" => "COURS", "label" => "Leçons", "kind" => "receipt",
                                                 "category" => "bnc", "enabled" => "1"}).status.should eq(302)
    settings_nature("COURS").label.should eq("Leçons")
  end

  it "ajoute un taux daté, l'affiche avec son libellé, puis le supprime" do
    browser = settings_books
    page = browser.get("/micro/parameters").html
    page.should contain("Cotisations sociales · Prestations de services (BNC)")
    saved = browser.post("/micro/parameters", {"code" => "rate.social.bnc", "valid_from" => "2027-01-01", "value" => "27,5"})
    saved.headers["Location"].should eq("/micro/parameters")
    row = Micro.parameters(Books.system, "rate.social.bnc").find! { |item| item.valid_from == Books.date("2027-01-01") }
    row.value.should eq(Books.d("27.5"))
    browser.post("/micro/parameters", {"code" => "rate.unknown", "valid_from" => "2027-01-01", "value" => "1"}).status.should eq(422)
    browser.post("/micro/parameters/#{row.id}/delete").status.should eq(302)
    Micro.parameters(Books.system, "rate.social.bnc").none? { |item| item.valid_from == Books.date("2027-01-01") }.should be_true
  end

  it "donne une nature de recette à un article" do
    browser = settings_books
    items = Partiduo::Api::Cards.category_by_code(Books.system, "SALE") || raise "catégorie SALE absente"
    card = Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(category_id: items.id,
      name: "Leçon de piano", code: "PIANO")).value!
    browser.get("/micro/items").html.should contain("Leçon de piano")
    browser.post("/micro/items", {"item_card_id" => card.id.to_s, "nature_id" => settings_nature("FEE").id.to_s})
      .status.should eq(302)
    Micro.item_natures(Books.system).map { |row| {row.item_card_id, row.nature_id} }
      .should eq([{card.id, settings_nature("FEE").id}])
  end

  it "bascule vers la TVA : articles en franchise, taux proposé, TVA déductible des achats et récapitulatif" do
    browser = settings_books
    franchise = Partiduo::Api::Vat.rates(Books.system).find! { |rate| rate.exemption_code == "VATEX-FR-FRANCHISE" }
    items = Partiduo::Api::Cards.category_by_code(Books.system, "SALE") || raise "catégorie SALE absente"
    Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(category_id: items.id,
      name: "Atelier", code: "ATELIER", vat_rate_id: franchise.id)).value!
    plan = browser.get("/micro/switch/vat").html
    plan.should contain("ATELIER")
    browser.get("/micro/purchases/new").html.should_not contain(%(name="vat_amount"))
    suggested = Micro.vat_switch_plan(Books.system).suggested_rate_id || raise "aucun taux proposé"
    done = browser.post("/micro/switch/vat", {"effective_on" => "2026-03-01", "rate_id" => suggested.to_s})
    done.headers["Location"].should eq("/micro/settings")
    Micro.settings(Books.system).vat_liable_since.should eq(Books.date("2026-03-01"))
    browser.get("/micro/switch/vat").html.should contain("TVA due depuis le")

    browser.get("/micro/purchases/new").html.should contain(%(name="vat_amount"))
    browser.post("/micro/purchases/new", {"amount" => "120", "vat_amount" => "20", "date" => "2026-03-12",
                                          "nature_id" => settings_nature("GOODS").id.to_s, "method" => "card"}).status.should eq(302)
    line = Micro.purchases(Books.system).first
    line.vat_amount.should eq(Books.d("20"))
    list = browser.get("/micro/purchases?year=2026").html
    list.should contain("Dont Achats de marchandises")
    list.should contain("120,00 €")
    # Tableau de bord : dépensé hors TVA déductible.
    browser.get("/").html.should contain("100,00 €")
  end

  it "bascule vers le régime réel, puis republie les registres et paramètre les comptes" do
    browser = settings_books
    Micro.record_receipt(Books.system, Micro::ReceiptInput.new(date: Books.date("2026-03-10"),
      nature_id: settings_nature("SERVICE").id, amount: Books.d("250"), method: "transfer")).value!
    browser.get("/micro/switch/real").html.should contain("Passer au régime réel")
    done = browser.post("/micro/switch/real", {"effective_on" => "2027-01-01"})
    done.headers["Location"].should eq("/micro/settings")
    Partiduo::Api::Modules.list(Books.system).find! { |item| item.code == "ACCOUNTING" }.active.should be_true
    settings = browser.get("/micro/settings").html
    settings.should contain("/micro/republish")
    settings.should contain("/accounting/micro-accounts")
    browser.follow(browser.post("/micro/republish")).html.should contain("lignes republiées vers la Comptabilité")

    accounts = browser.get("/accounting/micro-accounts")
    accounts.status.should eq(200)
    accounts.html.should contain("TVA déductible")
    accounts.html.should_not contain("missing translation")
    browser.post("/accounting/micro-accounts", {"key" => "bnc", "account" => "706"}).status.should eq(302)
    Partiduo::Api::Accounting.micro_accounts(Books.system).map { |row| {row.key, row.account.number} }
      .should eq([{"bnc", "706"}])
    browser.post("/accounting/micro-accounts", {"key" => "bnc", "account" => "99999999"}).status.should eq(422)
  end

  it "refuse les écrans de paramétrage sans le droit de paramétrer" do
    settings_books
    profile = PartiduoUi::Accounts.profile("Lecture micro", %w[micro.register.read])
    PartiduoUi::Accounts.create("lectrice-micro@exemple.test", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("lectrice-micro@exemple.test")
    %w[/micro/natures /micro/parameters /micro/items /micro/switch/vat /micro/switch/real].each do |path|
      reader.get(path).status.should eq(403), path
    end
    reader.post("/micro/republish").status.should eq(403)
  end
end
