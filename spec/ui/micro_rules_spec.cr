# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot G (tests) : cas limites du mode simplifié de la micro-entreprise
# (ADR-007 D3) — permissions du manifeste à l'écran, lignes inconnues,
# saisies refusées par le contrat, annulation, années, déclaration URSSAF,
# paramètres. Tout par `Partiduo::Api`.

private alias Micro = Partiduo::Api::Micro
private alias Books = PartiduoUi::Books

# Dossier micro-entreprise (Micro et Facturation actifs, Comptabilité
# inactive), administrateur connecté.
private def micro_rules_books : PartiduoUi::Browser
  browser = Books.admin
  Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
  Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  Partiduo::Api::Modules.activate(Books.system, "MICRO").success?.should be_true
  Micro.load_defaults(Books.system)
  browser
end

private def micro_nature(code : String) : Micro::NatureView
  Micro.natures(Books.system).find! { |item| item.code == code }
end

private def micro_receipt(day : String, amount : String, code : String = "SERVICE") : Micro::LineView
  input = Micro::ReceiptInput.new(date: Books.date(day), nature_id: micro_nature(code).id, amount: Books.d(amount),
    method: "transfer", party_name: "Atelier Morel")
  Micro.record_receipt(Books.system, input).value!
end

# Utilisateur `email` connecté, au profil ne portant que `permissions`.
private def micro_user(email : String, permissions : Array(String)) : PartiduoUi::Browser
  profile = PartiduoUi::Accounts.profile("Profil #{email}", permissions)
  PartiduoUi::Accounts.create(email, profile: nil, profile_id: profile)
  PartiduoUi::Accounts.signed_in(email)
end

describe "Mode simplifié de la micro-entreprise — permissions à l'écran" do
  it "laisse le lecteur consulter sans rien saisir, annuler ni paramétrer" do
    micro_rules_books
    line = micro_receipt("2026-03-10", "100")
    reader = micro_user("lecteur@example.com", ["micro.register.read"])
    list = reader.get("/micro/receipts?year=2026")
    list.status.should eq(200)
    list.html.should contain("Atelier Morel")
    list.html.should_not contain(%(href="/micro/receipts/new"))
    detail = reader.get("/micro/receipts/#{line.id}")
    detail.status.should eq(200)
    detail.html.should_not contain("Annuler cette ligne")
    reader.get("/micro/receipts/new").status.should eq(403)
    reader.post("/micro/receipts/new", {"amount" => "5", "date" => "2026-03-11", "nature_id" => micro_nature("SALE").id.to_s,
                                        "method" => "cash"}).status.should eq(403)
    reader.post("/micro/receipts/#{line.id}/reverse").status.should eq(403)
    reader.post("/micro/urssaf/declare", {"starts_on" => "2026-01-01"}).status.should eq(403)
    reader.get("/micro/settings").status.should eq(403)
    reader.post("/micro/settings", {"periodicity" => "monthly"}).status.should eq(403)
    Micro.receipts(Books.system).size.should eq(1)
    Micro.declarations(Books.system, 2026).first.status.should_not eq("declared")
    Micro.settings(Books.system).periodicity.should eq("quarterly")
    # Le lecteur est bien en mode simplifié, sans l'entrée des paramètres.
    home = reader.get("/").html
    home.should contain("pd-simple")
    home.should_not contain(%(href="/micro/settings"))
  end

  it "n'offre pas le mode simplifié à qui ne lit pas les registres, et lui refuse les écrans" do
    micro_rules_books
    other = micro_user("autre@example.com", ["cards.card.read"])
    other.get("/").html.should_not contain("pd-simple")
    other.get("/micro/receipts").status.should eq(403)
    other.get("/micro/urssaf").status.should eq(403)
    other.post("/mode", {"mode" => "simple"}).status.should eq(403)
  end

  it "répond 404 à toute saisie quand le module est inactif" do
    browser = Books.admin
    browser.post("/micro/receipts/new", {"amount" => "5", "date" => "2026-03-11", "nature_id" => "1", "method" => "cash"})
      .status.should eq(404)
    browser.post("/micro/purchases/1/reverse").status.should eq(404)
    browser.post("/micro/urssaf/declare", {"starts_on" => "2026-01-01"}).status.should eq(404)
    browser.post("/micro/settings", {"periodicity" => "monthly"}).status.should eq(404)
  end
end

describe "Mode simplifié de la micro-entreprise — saisies et cas limites" do
  it "répond 404 pour une ligne inconnue" do
    browser = micro_rules_books
    browser.get("/micro/receipts/999999").status.should eq(404)
    browser.get("/micro/purchases/999999").status.should eq(404)
    browser.post("/micro/receipts/999999/reverse").status.should eq(404)
  end

  it "affiche les refus du contrat sur le formulaire, saisie conservée" do
    browser = micro_rules_books
    negative = browser.post("/micro/purchases/new", {"amount" => "-5", "date" => "2026-03-12",
                                                     "nature_id" => micro_nature("SUPPLIES").id.to_s, "method" => "card",
                                                     "party_name" => "Papeterie Centrale"})
    negative.status.should eq(422)
    negative.html.should contain("Le montant doit être positif")
    negative.html.should contain(%(value="Papeterie Centrale"))
    unreadable = browser.post("/micro/purchases/new", {"amount" => "douze", "date" => "2026-03-12",
                                                       "nature_id" => micro_nature("SUPPLIES").id.to_s, "method" => "card"})
    unreadable.status.should eq(422)
    unreadable.html.should contain("Indiquez un nombre")
    wrong_register = browser.post("/micro/purchases/new", {"amount" => "5", "date" => "2026-03-12",
                                                           "nature_id" => micro_nature("SALE").id.to_s, "method" => "card"})
    wrong_register.status.should eq(422)
    wrong_register.html.should contain("Nature inconnue")
    too_much_vat = browser.post("/micro/receipts/new", {"amount" => "10", "vat_amount" => "10", "date" => "2026-03-12",
                                                        "nature_id" => micro_nature("SALE").id.to_s, "method" => "cash"})
    too_much_vat.status.should eq(422)
    too_much_vat.html.should contain("La TVA ne peut atteindre le montant encaissé")
    no_date = browser.post("/micro/receipts/new", {"amount" => "10", "date" => "",
                                                   "nature_id" => micro_nature("SALE").id.to_s, "method" => "cash"})
    no_date.status.should eq(422)
    Micro.receipts(Books.system).should be_empty
    Micro.purchases(Books.system).should be_empty
  end

  it "annule une recette une seule fois et signale la seconde tentative" do
    browser = micro_rules_books
    line = micro_receipt("2026-03-10", "100")
    first = browser.post("/micro/receipts/#{line.id}/reverse")
    first.headers["Location"].should eq("/micro/receipts/#{line.id}")
    reversal_id = Micro.receipt(Books.system, line.id).reversed_by_id || raise "recette non annulée"
    reversal = Micro.receipt(Books.system, reversal_id)
    reversal.amount.should eq(Books.d("-100"))
    browser.follow(first)
    # Une annulation ne s'annule pas : message du contrat, rien d'inscrit.
    second = browser.post("/micro/receipts/#{reversal_id}/reverse")
    browser.follow(second).html.should contain("Une contre-passation ne se contre-passe pas")
    Micro.receipts(Books.system).size.should eq(2)
    list = browser.get("/micro/receipts?year=#{reversal.date.year}").html
    list.should contain("pd-row-closed")
  end

  it "liste une année à la fois et retombe sur l'année en cours pour une année illisible" do
    browser = micro_rules_books
    today = Partiduo::Api::Core.today
    micro_receipt(today.to_s("%Y-%m-%d"), "77", "SALE")
    browser.get("/micro/receipts?year=#{today.year - 1}").html.should_not contain("77,00 €")
    browser.get("/micro/receipts?year=#{today.year}").html.should contain("77,00 €")
    %w[abc 1999 9999].each do |year|
      response = browser.get("/micro/receipts?year=#{year}")
      response.status.should eq(200)
      response.html.should contain("77,00 €")
    end
    csv = browser.get("/micro/receipts?year=#{today.year - 1}&format=csv")
    String.new(csv.content.to_slice).lines.size.should eq(1)
  end

  it "refuse de noter la déclaration d'une période en cours ou d'une date illisible" do
    browser = micro_rules_books
    today = Partiduo::Api::Core.today
    current = Micro.declarations(Books.system, today.year).find! { |item| item.status == "open" }
    refused = browser.post("/micro/urssaf/declare", {"starts_on" => current.starts_on.to_s("%Y-%m-%d")})
    browser.follow(refused).html.should contain("La déclaration suit la fin de la période")
    unreadable = browser.post("/micro/urssaf/declare", {"starts_on" => "hier"})
    unreadable.headers["Location"].should eq("/micro/urssaf")
    Micro.declarations(Books.system, today.year).none?(&.status.==("declared")).should be_true
  end

  it "refuse une périodicité inconnue dans les paramètres" do
    browser = micro_rules_books
    refused = browser.post("/micro/settings", {"periodicity" => "weekly", "activity_started_on" => "2026-02-01"})
    refused.status.should eq(422)
    Micro.settings(Books.system).periodicity.should eq("quarterly")
  end
end
