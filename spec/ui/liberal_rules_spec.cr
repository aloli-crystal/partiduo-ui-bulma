# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot L (tests) : cas limites des écrans de la profession libérale
# (ADR-007 D6) — permissions du manifeste à l'écran, module inactif,
# identifiants inconnus, saisies refusées par le contrat (réponse 422),
# annulations, années demandées, ajustements d'une année close. Tout par
# `Partiduo::Api`.

private alias Liberal = Partiduo::Api::Liberal
private alias Books = PartiduoUi::Books

# Dossier d'un libéral (module liberal et Facturation, Comptabilité inactive),
# administrateur connecté.
private def liberal_rules_books : PartiduoUi::Browser
  browser = Books.admin
  Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
  Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
  Liberal.load_defaults(Books.system)
  browser
end

private def liberal_nature(code : String) : Liberal::NatureView
  Liberal.natures(Books.system).find! { |item| item.code == code }
end

private def liberal_expense(day : String, amount : String, code : String = "RENT") : Liberal::LineView
  input = Liberal::LineInput.new(date: Books.date(day), nature_id: liberal_nature(code).id, amount: Books.d(amount),
    method: "transfer", party_name: "SCI du Parc")
  Liberal.record_expense(Books.system, input).value!
end

private def liberal_asset(day : String = "2026-04-01", amount : String = "3000") : Liberal::AssetView
  input = Liberal::AssetInput.new(label: "Table de massage", category: "equipment", acquired_on: Books.date(day),
    amount: Books.d(amount), duration_years: 3, method: "transfer")
  Liberal.record_asset(Books.system, input).value!
end

# Utilisateur `email` connecté, au profil ne portant que `permissions`.
private def liberal_user(email : String, permissions : Array(String)) : PartiduoUi::Browser
  profile = PartiduoUi::Accounts.profile("Profil #{email}", permissions)
  PartiduoUi::Accounts.create(email, profile: nil, profile_id: profile)
  PartiduoUi::Accounts.signed_in(email)
end

describe "Écrans de la profession libérale — permissions à l'écran" do
  it "laisse le lecteur consulter sans rien saisir, annuler, céder ni paramétrer" do
    liberal_rules_books
    line = liberal_expense("2026-03-10", "100")
    item = liberal_asset
    reader = liberal_user("lecteur@example.com", ["liberal.register.read"])
    list = reader.get("/liberal/expenses?year=2026")
    list.status.should eq(200)
    list.html.should contain("SCI du Parc")
    list.html.should_not contain(%(href="/liberal/expenses/new"))
    detail = reader.get("/liberal/lines/#{line.id}")
    detail.status.should eq(200)
    detail.html.should_not contain("/liberal/lines/#{line.id}/edit")
    detail.html.should_not contain("/liberal/lines/#{line.id}/delete")
    asset_page = reader.get("/liberal/assets/#{item.id}")
    asset_page.status.should eq(200)
    asset_page.html.should_not contain(%(href="/liberal/assets/#{item.id}/dispose"))
    tax = reader.get("/liberal/tax-return?year=2026")
    tax.status.should eq(200)
    tax.html.should_not contain(%(action="/liberal/tax-return/adjustments))

    %w[/liberal/receipts/new /liberal/expenses/new /liberal/assets/new /liberal/settings /liberal/natures
      /liberal/form-lines].each { |path| reader.get(path).status.should eq(403), path }
    reader.get("/liberal/assets/#{item.id}/dispose").status.should eq(403)
    reader.post("/liberal/expenses/new", {"amount" => "5", "date" => "2026-03-11", "nature_id" => liberal_nature("RENT").id.to_s,
                                          "method" => "cash"}).status.should eq(403)
    reader.post("/liberal/lines/#{line.id}/reverse").status.should eq(403)
    reader.post("/liberal/assets/#{item.id}/reverse").status.should eq(403)
    reader.post("/liberal/assets/#{item.id}/dispose", {"date" => "2026-06-30", "price" => "1", "method" => "cash"})
      .status.should eq(403)
    reader.post("/liberal/tax-return/adjustments?year=2026", {"kind" => "deduction", "label" => "X", "amount" => "5"})
      .status.should eq(403)
    reader.post("/liberal/settings", {"profession" => "Pirate"}).status.should eq(403)
    reader.post("/liberal/defaults").status.should eq(403)
    reader.post("/liberal/republish").status.should eq(403)

    Liberal.lines(Books.system).size.should eq(1)
    Liberal.asset(Books.system, item.id).disposal.should be_nil
    Liberal.adjustments(Books.system, 2026).should be_empty
    Liberal.settings(Books.system).profession.should_not eq("Pirate")
    home = reader.get("/").html
    home.should contain("pd-simple")
    home.should_not contain(%(href="/liberal/settings"))
  end

  it "laisse le saisisseur inscrire sans paramétrer" do
    liberal_rules_books
    clerk = liberal_user("saisie@example.com", ["liberal.register.read", "liberal.register.write"])
    clerk.get("/liberal/receipts/new").status.should eq(200)
    saved = clerk.post("/liberal/receipts/new", {"amount" => "70", "date" => "2026-03-11",
                                                 "nature_id" => liberal_nature("RECEIPTS").id.to_s, "method" => "cheque"})
    saved.status.should eq(302)
    Liberal.lines(Books.system).first.amount.should eq(Books.d("70"))
    clerk.get("/liberal/settings").status.should eq(403)
    clerk.post("/liberal/natures", {"code" => "X", "label" => "X", "kind" => "receipt", "heading" => "receipts"})
      .status.should eq(403)
    clerk.post("/liberal/form-lines", {"millesime" => "2026", "item" => "rent", "form" => "2035-A", "line" => "1", "box" => "A"})
      .status.should eq(403)
  end

  it "refuse les écrans à qui ne lit pas le livre-journal, sans mode simplifié" do
    liberal_rules_books
    other = liberal_user("autre@example.com", ["cards.card.read"])
    other.get("/").html.should_not contain("pd-simple")
    %w[/liberal/journal /liberal/receipts /liberal/expenses /liberal/assets /liberal/tax-return].each do |path|
      other.get(path).status.should eq(403), path
    end
  end

  it "répond 404 à toute saisie quand le module est inactif" do
    browser = Books.admin
    browser.post("/liberal/receipts/new", {"amount" => "5", "date" => "2026-03-11", "nature_id" => "1", "method" => "cash"})
      .status.should eq(404)
    browser.post("/liberal/lines/1/reverse").status.should eq(404)
    browser.post("/liberal/assets/new", {"amount" => "5"}).status.should eq(404)
    browser.post("/liberal/tax-return/adjustments?year=2026", {"kind" => "deduction", "label" => "X", "amount" => "5"})
      .status.should eq(404)
    browser.post("/liberal/settings", {"profession" => "X"}).status.should eq(404)
    browser.post("/liberal/republish").status.should eq(404)
    browser.get("/liberal/lines/1").status.should eq(404)
  end
end

describe "Écrans de la profession libérale — refus et cas limites" do
  it "répond 404 à une ligne, une immobilisation ou une nature inconnues" do
    browser = liberal_rules_books
    browser.get("/liberal/lines/999999").status.should eq(404)
    browser.post("/liberal/lines/999999/reverse").status.should eq(404)
    browser.get("/liberal/assets/999999").status.should eq(404)
    browser.get("/liberal/assets/999999/dispose").status.should eq(404)
    browser.post("/liberal/assets/999999/reverse").status.should eq(404)
    browser.get("/liberal/natures/999999").status.should eq(404)
  end

  it "réaffiche la saisie refusée par le contrat : date à venir, rubrique de l'autre sens, montant au millième" do
    browser = liberal_rules_books
    future = browser.post("/liberal/receipts/new", {"amount" => "10", "date" => "2026-12-31",
                                                    "nature_id" => liberal_nature("RECEIPTS").id.to_s, "method" => "cash"})
    future.status.should eq(422)
    future.html.should_not contain("missing translation")
    wrong = browser.post("/liberal/receipts/new", {"amount" => "10", "date" => "2026-03-10",
                                                   "nature_id" => liberal_nature("RENT").id.to_s, "method" => "cash"})
    wrong.status.should eq(422)
    scale = browser.post("/liberal/expenses/new", {"amount" => "10,005", "date" => "2026-03-10",
                                                   "nature_id" => liberal_nature("RENT").id.to_s, "method" => "cash"})
    scale.status.should eq(422)
    scale.html.should contain("Le montant s'exprime au centime")
    Liberal.lines(Books.system).should be_empty
  end

  it "n'annule pas deux fois une ligne et n'offre pas d'annuler une annulation" do
    browser = liberal_rules_books
    line = liberal_expense("2026-03-12", "80")
    browser.post("/liberal/lines/#{line.id}/reverse").status.should eq(302)
    reversal_id = Liberal.line(Books.system, line.id).reversed_by_id || raise "ligne non annulée"
    again = browser.post("/liberal/lines/#{line.id}/reverse")
    again.headers["Location"].should eq("/liberal/lines/#{line.id}")
    browser.follow(again).html.should contain("is-danger")
    browser.get("/liberal/lines/#{reversal_id}").html.should_not contain(%(action="/liberal/lines/#{reversal_id}/reverse"))
    browser.post("/liberal/lines/#{reversal_id}/reverse").status.should eq(302)
    Liberal.lines(Books.system).size.should eq(2)
  end

  it "refuse une cession invalide (422) et ne propose plus de céder un bien cédé ni d'annuler un bien d'une autre année" do
    browser = liberal_rules_books
    item = liberal_asset
    empty = browser.post("/liberal/assets/#{item.id}/dispose", {"date" => "2026-06-30", "price" => "", "method" => "transfer"})
    empty.status.should eq(422)
    empty.html.should contain("Ce champ est obligatoire.")
    early = browser.post("/liberal/assets/#{item.id}/dispose", {"date" => "2026-03-01", "price" => "10", "method" => "transfer"})
    early.status.should eq(422)
    early.html.should_not contain("missing translation")
    Liberal.asset(Books.system, item.id).disposal.should be_nil
    browser.post("/liberal/assets/#{item.id}/dispose", {"date" => "2026-06-30", "price" => "10", "method" => "transfer"})
      .status.should eq(302)
    page = browser.get("/liberal/assets/#{item.id}").html
    page.should_not contain(%(href="/liberal/assets/#{item.id}/dispose"))
    page.should_not contain(%(action="/liberal/assets/#{item.id}/reverse"))
    twice = browser.post("/liberal/assets/#{item.id}/dispose", {"date" => "2026-07-01", "price" => "20", "method" => "transfer"})
    twice.status.should eq(422)

    PartiduoUi::Reference.fiscal_year(2025)
    old = liberal_asset("2025-05-02", "900")
    browser.get("/liberal/assets/#{old.id}").html.should_not contain(%(action="/liberal/assets/#{old.id}/reverse"))
    browser.post("/liberal/assets/#{old.id}/reverse").status.should eq(302)
    Liberal.asset(Books.system, old.id).reversed_by_id.should be_nil
  end

  it "ramène une année illisible ou hors bornes à l'année en cours" do
    browser = liberal_rules_books
    year = Partiduo::Api::Core.today.year
    %w[abc 1999 3000 -1].each do |value|
      response = browser.get("/liberal/journal?year=#{value}")
      response.status.should eq(200)
      response.html.should contain("Livre-journal #{year}")
      browser.get("/liberal/tax-return?year=#{value}").html.should contain("revenus #{year}")
    end
  end

  it "refuse des paramètres invalides avec 422" do
    browser = liberal_rules_books
    bad_date = browser.post("/liberal/settings", {"profession" => "Infirmière", "activity_started_on" => "31/02/2020"})
    bad_date.status.should eq(422)
    too_long = browser.post("/liberal/settings", {"profession" => "x" * 101})
    too_long.status.should eq(422)
    Liberal.settings(Books.system).profession.should_not eq("Infirmière")
    wrong_nature = browser.post("/liberal/settings", {"profession"        => "Infirmière",
                                                      "default_nature_id" => liberal_nature("RENT").id.to_s})
    wrong_nature.status.should eq(422)
  end

  it "fige les réintégrations et déductions d'une année dont une période est close" do
    browser = liberal_rules_books
    adjustment = Liberal.add_adjustment(Books.system, Liberal::AdjustmentInput.new(2026, "deduction", "Exonération",
      Books.d("50"))).value!
    period = Partiduo::Api::Core.period_for(Books.system, Books.date("2026-01-15")) || raise "pas de période"
    Partiduo::Api::Core.close_period(Books.system, period.id).value!
    page = browser.get("/liberal/tax-return?year=2026").html
    page.should contain("Exonération")
    page.should_not contain(%(action="/liberal/adjustments/#{adjustment.id}/delete))
    removed = browser.post("/liberal/adjustments/#{adjustment.id}/delete?year=2026")
    removed.headers["Location"].should eq("/liberal/tax-return?year=2026")
    browser.follow(removed).html.should contain("is-danger")
    Liberal.adjustments(Books.system, 2026).size.should eq(1)
    added = browser.post("/liberal/tax-return/adjustments?year=2026", {"kind" => "deduction", "label" => "Autre", "amount" => "5"})
    added.status.should eq(422)
    Liberal.adjustments(Books.system, 2026).size.should eq(1)
  end
end
