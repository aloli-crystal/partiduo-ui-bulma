# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — écrans du Stock : dépôts et dépôt par défaut, articles suivis,
# opérations manuelles, inventaire, éditions (état, historique,
# valorisation) et exports.

private alias Stk = Partiduo::Api::Stock
private alias Books = PartiduoUi::Books

private record StockSetup, browser : PartiduoUi::Browser, repository : Stk::RepositoryView,
  screw : Partiduo::Api::Cards::CardView, nut : Partiduo::Api::Cards::CardView

# Dossier de test, module Stock actif, un dépôt, deux articles suivis.
private def stock_books : StockSetup
  browser = Books.admin
  Partiduo::Api::Modules.activate(Books.system, "STOCK").success?.should be_true
  repository = Stk.create_repository(Books.system, Stk::RepositoryInput.new("Entrepôt Lyon", city: "Lyon")).value!
  screw = Books.card("SALE", "Vis inox", "VIS")
  nut = Books.card("SALE", "Écrou", "ECROU")
  Stk.track_item(Books.system, Stk::ItemInput.new(screw.id)).success?.should be_true
  Stk.track_item(Books.system, Stk::ItemInput.new(nut.id)).success?.should be_true
  StockSetup.new(browser, repository, screw, nut)
end

private def receive(setup : StockSetup, card : Partiduo::Api::Cards::CardView, quantity : String, cost : String? = nil,
                    day : String = "2026-03-10") : Stk::ChangeView
  line = Stk::ChangeLineInput.new(card.id, Books.d(quantity), cost.try { |text| Books.d(text) })
  Stk.record_change(Books.system, Stk::ChangeInput.new(setup.repository.id, Books.date(day), [line])).value!
end

describe "Stock (lot 6)" do
  it "n'expose aucun écran quand le module est inactif" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "STOCK")
    %w[/stock/repositories /stock/items /stock/changes /stock/changes/new /stock/inventory /stock/state
      /stock/history /stock/valuation].each do |path|
      browser.get(path).status.should eq(404)
    end
  end

  it "crée un dépôt, le règle par défaut et suit un article par les formulaires" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "STOCK").success?.should be_true
    browser.get("/stock/repositories").html.should contain("Aucun dépôt n'est défini.")
    created = browser.post("/stock/repositories/new", {"name" => "Dépôt central", "city" => "Nantes", "country_code" => "fr"})
    created.status.should eq(302)
    repository = Stk.repositories(Books.system).first
    repository.country_code.should eq("FR")
    repository.default.should be_true
    created.headers["Location"].should eq("/stock/repositories/#{repository.id}")
    browser.post("/stock/repositories/new", {"name" => "dépôt central"}).status.should eq(422)

    browser.post("/stock/settings", {"default_repository_id" => ""}).status.should eq(302)
    Stk.settings(Books.system).default_repository_id.should be_nil
    browser.post("/stock/settings", {"default_repository_id" => repository.id.to_s}).status.should eq(302)
    Stk.settings(Books.system).default_repository_id.should eq(repository.id)

    card = Books.card("SALE", "Vis inox", "VIS")
    browser.get("/stock/items/new").html.should contain("VIS · Vis inox")
    browser.post("/stock/items/new", {"card_id" => card.id.to_s, "stock_code" => "vis-8"}).status.should eq(302)
    Stk.item(Books.system, card.id).try(&.stock_code).should eq("VIS-8")
    page = browser.get("/stock/items").html
    page.should contain("VIS-8")
    page.should contain(%(href="/stock/items/#{card.id}/edit"))
    browser.post("/stock/items/#{card.id}/delete").status.should eq(302)
    Stk.item(Books.system, card.id).should be_nil

    browser.post("/stock/repositories/#{repository.id}/delete").status.should eq(302)
    Stk.repositories(Books.system).should be_empty
  end

  it "saisit une opération manuelle : entrée, sortie, refus sous la ligne" do
    setup = stock_books
    form = setup.browser.get("/stock/changes/new").html
    form.should contain(%(name="lines-0-quantity"))
    form.should contain(%(value="#{setup.repository.id}" selected))

    refused = setup.browser.post("/stock/changes/new", {"repository_id" => setup.repository.id.to_s, "date" => "2026-03-10",
                                                        "lines-0-card_id" => setup.screw.id.to_s, "lines-0-quantity" => "0"})
    refused.status.should eq(422)
    refused.html.should contain("La quantité ne peut être nulle.")

    ok = setup.browser.post("/stock/changes/new", {"repository_id" => setup.repository.id.to_s, "date" => "2026-03-10",
                                                   "comment" => "Réception", "lines-0-card_id" => setup.screw.id.to_s, "lines-0-quantity" => "100",
                                                   "lines-0-unit_cost" => "0,25", "lines-1-card_id" => setup.nut.id.to_s, "lines-1-quantity" => "-5"})
    ok.status.should eq(302)
    change = Stk.changes(Books.system).first
    ok.headers["Location"].should eq("/stock/changes/#{change.id}")
    change.movements.size.should eq(2)
    Stk.quantity(Books.system, setup.screw.id).should eq(Books.d("100"))
    Stk.quantity(Books.system, setup.nut.id).should eq(Books.d("-5"))

    detail = setup.browser.get("/stock/changes/#{change.id}").html
    detail.should contain("Réception")
    detail.should contain("Entrée")
    detail.should contain("Sortie")
    setup.browser.get("/stock/changes").html.should contain(%(href="/stock/changes/#{change.id}"))

    setup.browser.post("/stock/changes/#{change.id}/delete").status.should eq(302)
    Stk.changes(Books.system).should be_empty
  end

  it "prépare puis enregistre un inventaire : l'écart devient un mouvement" do
    setup = stock_books
    receive(setup, setup.screw, "100", "0.25")
    prepare = setup.browser.post("/stock/inventory", {"repository_id" => setup.repository.id.to_s, "date" => "2026-04-01"})
    prepare.status.should eq(200)
    html = prepare.html
    html.should contain(%(name="prepared"))
    html.should contain("théorique : 100")

    lines = {} of String => String
    Stk.inventory_proposal(Books.system, setup.repository.id, Books.date("2026-04-01")).each_with_index do |line, index|
      lines["lines-#{index}-card_id"] = line.card_id.to_s
      lines["lines-#{index}-counted"] = line.card_id == setup.screw.id ? "90" : "0"
    end
    recorded = setup.browser.post("/stock/inventory", {"repository_id" => setup.repository.id.to_s, "date" => "2026-04-01",
                                                       "prepared" => "#{setup.repository.id}/2026-04-01"}.merge(lines))
    recorded.status.should eq(302)
    Stk.quantity(Books.system, setup.screw.id).should eq(Books.d("90"))
    inventory = Stk.changes(Books.system, Stk::ChangeQuery.new(kind: "inventory")).first
    inventory.movements.map(&.quantity).should eq([Books.d("10")])
  end

  it "laisse vide le compte d'un stock théorique négatif : l'inventaire s'enregistre sans correction" do
    setup = stock_books
    receive(setup, setup.screw, "100", "0.25")
    receive(setup, setup.nut, "-3")
    proposal = Stk.inventory_proposal(Books.system, setup.repository.id, Books.date("2026-04-01"))
    html = setup.browser.post("/stock/inventory", {"repository_id" => setup.repository.id.to_s, "date" => "2026-04-01"}).html
    # Champs tels que le navigateur les renverrait, valeurs préremplies comprises.
    lines = {} of String => String
    proposal.each_with_index do |line, index|
      input = html.match!(/<input[^>]*name="lines-#{index}-counted"[^>]*>/)[0]
      value = input.match(/value="([^"]*)"/).try(&.[1]) || ""
      value.should eq("") if line.card_id == setup.nut.id
      value.should eq("100") if line.card_id == setup.screw.id
      lines["lines-#{index}-card_id"] = line.card_id.to_s
      lines["lines-#{index}-counted"] = value
    end
    recorded = setup.browser.post("/stock/inventory", {"repository_id" => setup.repository.id.to_s, "date" => "2026-04-01",
                                                       "prepared" => "#{setup.repository.id}/2026-04-01"}.merge(lines))
    recorded.status.should eq(302)
    Stk.quantity(Books.system, setup.nut.id).should eq(Books.d("-3"))
    Stk.quantity(Books.system, setup.screw.id).should eq(Books.d("100"))
  end

  it "range l'erreur d'une ligne d'inventaire sous sa fiche, même après une fiche inconnue de la proposition" do
    setup = stock_books
    proposal = Stk.inventory_proposal(Books.system, setup.repository.id, Books.date("2026-04-01"))
    nut_index = proposal.index! { |line| line.card_id == setup.nut.id }
    # Fiche absente de la proposition (suivi retiré entre-temps) en tête :
    # ni envoyée au cœur, ni comptée dans les indices `lines[i]`.
    lines = {"lines-0-card_id" => "999999", "lines-0-counted" => "4"}
    proposal.each_with_index do |line, index|
      lines["lines-#{index + 1}-card_id"] = line.card_id.to_s
      lines["lines-#{index + 1}-counted"] = line.card_id == setup.nut.id ? "-1" : ""
    end
    refused = setup.browser.post("/stock/inventory", {"repository_id" => setup.repository.id.to_s, "date" => "2026-04-01",
                                                      "prepared" => "#{setup.repository.id}/2026-04-01"}.merge(lines))
    refused.status.should eq(422)
    html = refused.html
    html.should contain("lines-#{nut_index}-counted-errors")
    proposal.each_index do |index|
      html.should_not contain("lines-#{index}-counted-errors") unless index == nut_index
    end
  end

  it "affiche l'état, l'historique et la valorisation ; exporte en CSV" do
    setup = stock_books
    receive(setup, setup.screw, "100", "0.20", "2026-02-01")
    receive(setup, setup.screw, "100", "0.30", "2026-02-15")
    receive(setup, setup.screw, "-50", nil, "2026-03-01")

    state = setup.browser.get("/stock/state?from=2026-01-01&to=2026-12-31").html
    state.should contain("VIS")
    state.should contain("150")

    history = setup.browser.get("/stock/history?stock_code=vis&from=2026-01-01&to=2026-12-31").html
    history.should contain("Entrepôt Lyon")
    history.should contain("Opération manuelle")

    valuation = setup.browser.get("/stock/valuation?date=2026-12-31").html
    valuation.should contain("37,50")
    setup.browser.get("/cards/#{setup.screw.id}").html.should contain("/stock/history?stock_code=VIS&f=1")

    %w[/stock/state?f=1&from=2026-01-01&to=2026-12-31&format=csv /stock/history?f=1&format=csv
      /stock/valuation?f=1&date=2026-12-31&format=csv].each do |path|
      response = setup.browser.get(path)
      response.status.should eq(200)
      response.content_type.should start_with("text/csv")
      response.content.should contain("VIS")
    end
  end
end
