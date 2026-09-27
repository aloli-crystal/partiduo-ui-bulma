# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 5 — écrans de l'Analytique : plans, groupes et postes, paramètres,
# clés de répartition, ventilation dans la saisie et après coup,
# opérations diverses, éditions et exports.

private alias Acc = Partiduo::Api::Accounting
private alias Ana = Partiduo::Api::Analytic
private alias Books = PartiduoUi::Books

private record Setup, browser : PartiduoUi::Browser, activity : Ana::PlanView, project : Ana::PlanView,
  sale : Ana::PostView, workshop : Ana::PostView, p1 : Ana::PostView

# Dossier de test, module Analytique actif, deux plans : ACTIVITE (VENTE,
# ATELIER) et PROJET (P1).
private def analytic_books : Setup
  browser = Books.admin
  Partiduo::Api::Modules.activate(Books.system, "ANALYTIC").success?.should be_true
  system = Books.system
  activity = Ana.create_plan(system, Ana::PlanInput.new("Activite")).value!
  project = Ana.create_plan(system, Ana::PlanInput.new("Projet")).value!
  sale = Ana.create_post(system, Ana::PostInput.new(activity.id, "vente", "Ventes")).value!
  workshop = Ana.create_post(system, Ana::PostInput.new(activity.id, "atelier", "Atelier")).value!
  p1 = Ana.create_post(system, Ana::PostInput.new(project.id, "p1", "Projet 1")).value!
  Setup.new(browser, activity, project, sale, workshop, p1)
end

private def misc_values(values : Hash(String, String)) : Hash(String, String)
  {"ledger_id" => Books.ledger("O01").id.to_s, "date" => "2026-03-15", "receipt" => "", "label" => "Frais"}.merge(values)
end

# Charge de 100 au 603, contrepartie 101.
private def expense_values(extra = {} of String => String) : Hash(String, String)
  misc_values({"line-0-account" => "603", "line-0-debit" => "100", "line-1-account" => "101", "line-1-credit" => "100"}.merge(extra))
end

private def last_entry : Acc::EntryView
  Acc.entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("O01").id)).max_by(&.id)
end

private def first_entry : Acc::EntryView
  Acc.entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("O01").id)).min_by(&.id)
end

describe "Analytique (lot 5)" do
  it "n'expose aucun écran quand le module est inactif" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
    browser.get("/analytic/plans").status.should eq(404)
    browser.get("/analytic/reports").status.should eq(404)
    # Saisie inchangée : pas de colonne analytique.
    browser.get("/accounting/entries/misc").html.should_not contain("pd-col-analytic")
  end

  it "crée un plan, un groupe et un poste par les formulaires ; refus du contrat sous le champ" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "ANALYTIC").success?.should be_true
    browser.get("/analytic/plans").html.should contain("Aucun plan analytique n'est défini.")
    browser.get("/analytic/plans/new").status.should eq(200)

    created = browser.post("/analytic/plans/new", {"name" => "Activité commerciale", "description" => "Axe"})
    created.status.should eq(302)
    plan = Ana.plans(Books.system).first
    plan.name.should eq("ACTIVITÉCOMMERCIALE")
    created.headers["Location"].should eq("/analytic/plans/#{plan.id}")

    twice = browser.post("/analytic/plans/new", {"name" => "activité commerciale"})
    twice.status.should eq(422)
    twice.html.should contain("existe déjà")

    browser.post("/analytic/plans/#{plan.id}/groups/new", {"code" => "gr1", "description" => "Premier"}).status.should eq(302)
    group = Ana.groups(Books.system, plan.id).first
    group.code.should eq("GR1")
    browser.post("/analytic/plans/#{plan.id}/posts/new",
      {"code" => "vente", "description" => "Ventes", "group_id" => group.id.to_s, "active" => "1"}).status.should eq(302)
    post = Ana.posts(Books.system, plan.id).first
    post.code.should eq("VENTE")
    post.group_code.should eq("GR1")

    page = browser.get("/analytic/plans/#{plan.id}").html
    page.should contain(%(href="/analytic/posts/#{post.id}"))
    page.should contain("GR1")
    browser.get("/analytic/posts/#{post.id}").html.should contain("Grand livre du poste")

    browser.post("/analytic/posts/#{post.id}/edit", {"code" => "VENTE", "description" => "Ventes FR", "group_id" => ""}).status.should eq(302)
    Ana.post(Books.system, post.id).active.should be_false
    browser.post("/analytic/groups/#{group.id}/delete").status.should eq(302)
    Ana.groups(Books.system, plan.id).should be_empty
    browser.post("/analytic/posts/#{post.id}/delete").status.should eq(302)
    browser.post("/analytic/plans/#{plan.id}/delete").status.should eq(302)
    Ana.plans(Books.system).should be_empty
  end

  it "règle le mode de ventilation et les comptes ventilés" do
    setup = analytic_books
    setup.browser.get("/analytic/settings").html.should contain(%(name="account_filter"))
    refused = setup.browser.post("/analytic/settings", {"mode" => "mandatory", "account_filter" => "6,x"})
    refused.status.should eq(422)
    refused.html.should contain("Uniquement des chiffres séparés par des virgules.")
    setup.browser.post("/analytic/settings", {"mode" => "mandatory", "account_filter" => "6"}).status.should eq(302)
    settings = Ana.settings(Books.system)
    settings.mandatory.should be_true
    settings.account_filter.should eq("6")
  end

  it "crée une clé de répartition : lignes, postes par plan, journaux" do
    setup = analytic_books
    form = setup.browser.get("/analytic/keys/new").html
    form.should contain(%(name="rows-0-percent"))
    form.should contain(%(name="rows-0-p#{setup.activity.id}"))
    form.should contain(%(name="ledger-#{Books.ledger("O01").id}"))

    bad = setup.browser.post("/analytic/keys/new", {"name" => "Moitié", "rows-0-percent" => "50", "rows-0-p#{setup.activity.id}" => setup.sale.id.to_s})
    bad.status.should eq(422)
    bad.html.should contain("Le total ne vaut pas 100")

    ok = setup.browser.post("/analytic/keys/new", {
      "name" => "Répartition atelier",
      "rows-0-percent" => "60", "rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
      "rows-0-p#{setup.project.id}" => setup.p1.id.to_s,
      "rows-1-percent" => "40", "rows-1-p#{setup.activity.id}" => setup.workshop.id.to_s,
      "ledger-#{Books.ledger("O01").id}" => "1",
    })
    ok.status.should eq(302)
    key = Ana.keys(Books.system).first
    key.rows.map(&.percent).should eq([Books.d("60"), Books.d("40")])
    key.ledger_ids.should eq([Books.ledger("O01").id])
    page = setup.browser.get("/analytic/keys/#{key.id}").html
    page.should contain("Répartition atelier")
    page.should contain(%(href="/analytic/posts/#{setup.workshop.id}"))
  end

  it "ventile une ligne dans la saisie : un poste par plan, puis par une clé" do
    setup = analytic_books
    page = setup.browser.get("/accounting/entries/misc").html
    page.should contain("pd-col-analytic")
    page.should contain(%(name="line-0-ana-p#{setup.activity.id}"))

    response = setup.browser.post("/accounting/entries/misc", expense_values({
      "line-0-ana-p#{setup.activity.id}" => setup.workshop.id.to_s, "line-0-ana-p#{setup.project.id}" => setup.p1.id.to_s,
    }))
    response.status.should eq(302)
    entry = last_entry
    distributions = Ana.entry_distributions(Books.system, entry.id)
    distributions.size.should eq(1)
    distributions.first.rows.first.amount.should eq(Books.d("100"))
    distributions.first.rows.first.posts.map(&.code).sort!.should eq(%w[ATELIER P1])

    key = Ana.create_key(Books.system, Ana::KeyInput.new("Moitié", [
      Ana::KeyRowInput.new(Books.d("50"), [setup.sale.id]), Ana::KeyRowInput.new(Books.d("50"), [setup.workshop.id]),
    ])).value!
    setup.browser.post("/accounting/entries/misc", expense_values({"line-0-ana_key" => key.id.to_s})).status.should eq(302)
    rows = Ana.entry_distributions(Books.system, last_entry.id).first.rows
    rows.map(&.amount).should eq([Books.d("50"), Books.d("50")])
  end

  it "ventile une facture d'achat saisie : la ligne d'article" do
    setup = analytic_books
    supplier = Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    values = {"ledger_id" => Books.ledger("A01").id.to_s, "date" => "2026-03-18", "third_party" => supplier.code,
              "label" => "Abonnement", "line-0-account" => "603", "line-0-amount" => "72", "line-0-vat_rate" => "NOR",
              "line-0-ana-p#{setup.activity.id}" => setup.sale.id.to_s}
    setup.browser.post("/accounting/entries/purchase", values).status.should eq(302)
    entry = Acc.entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("A01").id)).first
    distribution = Ana.entry_distributions(Books.system, entry.id).first
    distribution.account_number.should eq("603")
    distribution.rows.first.amount.should eq(Books.d("72"))
  end

  it "refuse en mode obligatoire une saisie non ventilée, l'erreur sous la ligne" do
    setup = analytic_books
    Ana.update_settings(Books.system, Ana::SettingsInput.new(true, "6")).value!
    response = setup.browser.post("/accounting/entries/misc", expense_values)
    response.status.should eq(422)
    response.html.should contain("Analytique :")
    response.html.should contain(%(aria-describedby="pd-l0-errors"))
    Acc.count_entries(Books.system).should eq(0)
  end

  it "montre la ventilation à la consultation et la corrige après coup" do
    setup = analytic_books
    setup.browser.post("/accounting/entries/misc", expense_values).status.should eq(302)
    entry = last_entry
    shown = setup.browser.get("/accounting/entries/#{entry.id}").html
    shown.should contain("Écriture non ventilée.")
    shown.should contain(%(href="/analytic/entries/#{entry.id}"))

    form = setup.browser.get("/analytic/entries/#{entry.id}").html
    form.should contain(%(name="lines-0-rows-0-amount"))
    form.should contain("603")
    form.should_not contain(%(name="lines-1-rows-0-amount"))

    refused = setup.browser.post("/analytic/entries/#{entry.id}", {
      "lines-0-rows-0-amount" => "80", "lines-0-rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
      "lines-0-rows-1-amount" => "30", "lines-0-rows-1-p#{setup.activity.id}" => setup.workshop.id.to_s,
    })
    refused.status.should eq(422)

    saved = setup.browser.post("/analytic/entries/#{entry.id}", {
      "lines-0-rows-0-amount" => "80", "lines-0-rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
      "lines-0-rows-1-amount" => "", "lines-0-rows-1-p#{setup.activity.id}" => setup.workshop.id.to_s,
    })
    saved.status.should eq(302)
    saved.headers["Location"].should eq("/accounting/entries/#{entry.id}")
    Ana.entry_distributions(Books.system, entry.id).first.rows.map(&.amount).should eq([Books.d("80"), Books.d("20")])
    setup.browser.follow(saved).html.should contain(%(href="/analytic/posts/#{setup.sale.id}"))
  end

  it "saisit une opération diverse analytique équilibrée par plan" do
    setup = analytic_books
    setup.browser.get("/analytic/misc/new").html.should contain(%(name="rows-1-side"))
    unbalanced = setup.browser.post("/analytic/misc/new", {
      "date" => "2026-03-10", "description" => "Transfert",
      "rows-0-amount" => "30", "rows-0-side" => "debit", "rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
      "rows-1-amount" => "20", "rows-1-side" => "credit", "rows-1-p#{setup.activity.id}" => setup.workshop.id.to_s,
    })
    unbalanced.status.should eq(422)
    created = setup.browser.post("/analytic/misc/new", {
      "date" => "2026-03-10", "description" => "Transfert",
      "rows-0-amount" => "30", "rows-0-side" => "debit", "rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
      "rows-1-amount" => "30", "rows-1-side" => "credit", "rows-1-p#{setup.activity.id}" => setup.workshop.id.to_s,
    })
    created.status.should eq(302)
    operation = Ana.misc_operations(Books.system).first
    operation.description.should eq("Transfert")
    setup.browser.get("/analytic/misc").html.should contain(%(href="/analytic/misc/#{operation.id}"))
    setup.browser.post("/analytic/misc/#{operation.id}/delete").status.should eq(302)
    Ana.misc_operations(Books.system).should be_empty
  end

  it "affiche les éditions : balance, balance croisée, groupes, historique, grand livre, tableau, lignes à ventiler, CSV" do
    setup = analytic_books
    setup.browser.post("/accounting/entries/misc", expense_values({
      "line-0-ana-p#{setup.activity.id}" => setup.workshop.id.to_s, "line-0-ana-p#{setup.project.id}" => setup.p1.id.to_s,
    })).status.should eq(302)
    setup.browser.post("/accounting/entries/misc", expense_values({"line-0-debit" => "40", "line-1-credit" => "40"})).status.should eq(302)
    range = "from=2026-01-01&to=2026-12-31"

    balance = setup.browser.get("/analytic/reports?f=1&plan=#{setup.activity.id}&#{range}").html
    balance.should contain("<h1>Balance</h1>")
    balance.should contain("ATELIER")
    balance.should contain("100,00")
    balance.should contain(%(aria-current="page">Balance</a>))
    balance.should contain(%(href="/analytic/reports/ledger?plan=#{setup.activity.id}&post_from=ATELIER&post_to=ATELIER))

    csv = setup.browser.get("/analytic/reports?f=1&plan=#{setup.activity.id}&#{range}&format=csv")
    csv.status.should eq(200)
    csv.content_type.should start_with("text/csv")
    csv.content.should contain("ATELIER")

    cross = setup.browser.get("/analytic/reports/cross?f=1&plan=#{setup.activity.id}&other_plan=#{setup.project.id}&#{range}").html
    cross.should contain("ACTIVITE × PROJET")
    cross.should contain("P1")

    setup.browser.get("/analytic/reports/groups?f=1&plan=#{setup.activity.id}&#{range}").html.should contain("Sans groupe")
    history = setup.browser.get("/analytic/reports/history?f=1&plan=#{setup.activity.id}&#{range}").html
    history.should contain(%(href="/accounting/entries/#{first_entry.id}"))
    ledger = setup.browser.get("/analytic/reports/ledger?f=1&plan=#{setup.activity.id}&#{range}").html
    ledger.should contain("ATELIER · Atelier")
    ledger.should contain("Solde progressif")
    table = setup.browser.get("/analytic/reports/table?f=1&plan=#{setup.activity.id}&axis=account&#{range}").html
    table.should contain("603")

    undistributed = setup.browser.get("/analytic/reports/undistributed?f=1&#{range}").html
    undistributed.should contain("Lignes à ventiler")
    undistributed.should contain("40,00")
    undistributed.should contain(%(href="/analytic/entries/#{last_entry.id}"))
  end

  it "réserve les écrans de modification au droit d'écrire" do
    setup = analytic_books
    profile = PartiduoUi::Accounts.profile("Lecture analytique", %w[analytic.plan.read analytic.report.read])
    PartiduoUi::Accounts.create("bob@example.com", profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("bob@example.com")
    reader.get("/analytic/plans").status.should eq(200)
    reader.get("/analytic/plans").html.should_not contain("/analytic/plans/new")
    reader.get("/analytic/plans/new").status.should eq(403)
    reader.post("/analytic/plans/new", {"name" => "X"}).status.should eq(403)
    reader.get("/analytic/plans/#{setup.activity.id}").status.should eq(200)
  end
end
