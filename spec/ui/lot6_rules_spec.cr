# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — écrans du Stock, des prévisions et du Suivi : droits (403),
# objets inconnus (404), refus métier rendus sous le formulaire (422),
# alertes de ligne.

private alias Stk = Partiduo::Api::Stock
private alias Fup = Partiduo::Api::Followup
private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

# Dossier de test (administrateur « alice »), Stock et Suivi actifs, puis
# « bob », connecté avec les seules permissions citées.
private def bob(*permissions : String) : PartiduoUi::Browser
  Books.admin
  Partiduo::Api::Modules.activate(Books.system, "STOCK").success?.should be_true
  Partiduo::Api::Modules.activate(Books.system, "FOLLOWUP").success?.should be_true
  profile = PartiduoUi::Accounts.profile("Profil de Bob", permissions.to_a)
  PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
  PartiduoUi::Accounts.signed_in("bob@example.com")
end

private def status(browser : PartiduoUi::Browser, method : String, path : String) : {String, Int32}
  response = method == "POST" ? browser.post(path, {} of String => String) : browser.get(path)
  {"#{method} #{path}", response.status}
end

private def months : Array(Partiduo::Api::Core::PeriodView)
  Partiduo::Api::Core.periods(Books.system).select { |period| period.starts_on.year == 2026 && period.starts_on != period.ends_on }
end

describe "Lot 6 — droits des écrans" do
  it "Stock : la lecture ouvre les éditions, pas la saisie ni les réglages" do
    browser = bob(Stk::READ)
    repository = Stk.create_repository(Books.system, Stk::RepositoryInput.new("Dépôt")).value!
    %w[/stock/state /stock/history /stock/valuation /stock/repositories /stock/items].each do |path|
      status(browser, "GET", path).should eq({"GET #{path}", 200})
    end
    {
      "GET"  => %w[/stock/changes/new /stock/inventory /stock/items/new /stock/repositories/new],
      "POST" => ["/stock/changes/new", "/stock/inventory", "/stock/repositories/new", "/stock/settings",
                 "/stock/repositories/#{repository.id}/delete", "/stock/items/new"],
    }.each do |method, paths|
      paths.each { |path| status(browser, method, path).should eq({"#{method} #{path}", 403}) }
    end
    Stk.repositories(Books.system).size.should eq(1)
  end

  it "Stock : sans aucune permission, aucune édition" do
    browser = bob("cards.card.read")
    %w[/stock/state /stock/history /stock/valuation /stock/changes].each do |path|
      status(browser, "GET", path).should eq({"GET #{path}", 403})
    end
    browser.get("/stock/state?f=1&from=2026-01-01&to=2026-12-31&format=csv").status.should eq(403)
  end

  it "Suivi : la lecture ouvre les actions et les rappels, pas la saisie ni les réglages" do
    browser = bob(Fup::READ)
    type = Fup.create_action_type(Books.system, Fup::ActionTypeInput.new("DI", "Document interne")).value!
    action = Fup.create_action(Books.system, Fup::ActionInput.new(type.id, Books.date("2026-03-10"))).value!
    %w[/followup/actions /followup/reminders /followup/types /followup/tags].each do |path|
      status(browser, "GET", path).should eq({"GET #{path}", 200})
    end
    browser.get("/followup/actions/#{action.id}").status.should eq(200)
    {
      "GET"  => %w[/followup/actions/new /followup/types/new /followup/tags/new],
      "POST" => ["/followup/actions/new", "/followup/actions/#{action.id}/delete", "/followup/actions/#{action.id}/comment",
                 "/followup/actions/#{action.id}/state?state=closed", "/followup/types/defaults", "/followup/tags/new"],
    }.each do |method, paths|
      paths.each { |path| status(browser, method, path).should eq({"#{method} #{path}", 403}) }
    end
    Fup.action(Books.system, action.id).state.should eq("todo")
    Fup.action_types(Books.system).size.should eq(1)
  end

  it "Prévisions : la lecture des rapports ouvre la comparaison, pas l'écriture" do
    browser = bob(Acc::REPORT_READ)
    january = months[0]
    forecast = Acc.create_forecast(Books.system, Acc::ForecastInput.new("Budget", january.id, january.id)).value!
    ["/accounting/forecasts", "/accounting/forecasts/#{forecast.id}", "/accounting/forecasts/#{forecast.id}/report"].each do |path|
      status(browser, "GET", path).should eq({"GET #{path}", 200})
    end
    {
      "GET" => ["/accounting/forecasts/new", "/accounting/forecasts/#{forecast.id}/edit",
                "/accounting/forecasts/#{forecast.id}/categories/new"],
      "POST" => ["/accounting/forecasts/new", "/accounting/forecasts/#{forecast.id}/delete",
                 "/accounting/forecasts/#{forecast.id}/clone"],
    }.each do |method, paths|
      paths.each { |path| status(browser, method, path).should eq({"#{method} #{path}", 403}) }
    end
    Acc.forecasts(Books.system).size.should eq(1)
  end
end

describe "Lot 6 — objets inconnus et refus métier" do
  it "répond 404 pour un dépôt, une opération, une action ou une prévision inconnus" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "STOCK").success?.should be_true
    Partiduo::Api::Modules.activate(Books.system, "FOLLOWUP").success?.should be_true
    %w[/stock/repositories/999999 /stock/changes/999999 /followup/actions/999999 /followup/actions/999999/edit
      /accounting/forecasts/999999 /accounting/forecasts/999999/report].each do |path|
      status(browser, "GET", path).should eq({"GET #{path}", 404})
    end
  end

  it "refuse une opération de stock dans une période close, message sous le formulaire" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "STOCK").success?.should be_true
    repository = Stk.create_repository(Books.system, Stk::RepositoryInput.new("Dépôt")).value!
    card = Books.card("SALE", "Vis inox", "VIS")
    Stk.track_item(Books.system, Stk::ItemInput.new(card.id)).value!
    march = months[2]
    Partiduo::Api::Core.close_period(Books.system, march.id).success?.should be_true
    refused = browser.post("/stock/changes/new", {"repository_id" => repository.id.to_s, "date" => "2026-03-10",
                                                  "lines-0-card_id" => card.id.to_s, "lines-0-quantity" => "5"})
    refused.status.should eq(422)
    refused.html.should contain("La date 10/03/2026 tombe dans une période close.")
    Stk.changes(Books.system).should be_empty
  end

  it "signale en alerte un stock final négatif" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "STOCK").success?.should be_true
    repository = Stk.create_repository(Books.system, Stk::RepositoryInput.new("Dépôt")).value!
    card = Books.card("SALE", "Vis inox", "VIS")
    Stk.track_item(Books.system, Stk::ItemInput.new(card.id)).value!
    Stk.record_change(Books.system, Stk::ChangeInput.new(repository.id, Books.date("2026-03-10"),
      [Stk::ChangeLineInput.new(card.id, Books.d("-3"))])).value!
    browser.get("/stock/state?from=2026-01-01&to=2026-12-31").html.should contain("pd-row-warning")
  end

  it "refuse une action dont le commentaire est trop long, sans rien créer" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "FOLLOWUP").success?.should be_true
    type = Fup.create_action_type(Books.system, Fup::ActionTypeInput.new("DI", "Document interne")).value!
    refused = browser.post("/followup/actions/new", {"action_type_id" => type.id.to_s, "date" => "2026-03-10",
                                                     "priority" => "2", "state" => "todo", "comment" => "c" * 10_001})
    refused.status.should eq(422)
    Fup.count_actions(Books.system, Fup::ActionQuery.new(open_only: false)).should eq(0)
  end
end
