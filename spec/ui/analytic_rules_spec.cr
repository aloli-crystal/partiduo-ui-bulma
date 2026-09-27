# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 5 — écrans de l'Analytique, cas limites (specs du testeur) : droits
# par écran, identifiants inconnus, ventilation après coup par une clé ou
# retirée, périodes closes, échappement, exports de chaque édition.

private alias Acc = Partiduo::Api::Accounting
private alias Ana = Partiduo::Api::Analytic
private alias Books = PartiduoUi::Books

private record RulesSetup, browser : PartiduoUi::Browser, activity : Ana::PlanView, project : Ana::PlanView,
  sale : Ana::PostView, workshop : Ana::PostView, p1 : Ana::PostView

private def rules_books : RulesSetup
  browser = Books.admin
  Partiduo::Api::Modules.activate(Books.system, "ANALYTIC").success?.should be_true
  system = Books.system
  activity = Ana.create_plan(system, Ana::PlanInput.new("Activite")).value!
  project = Ana.create_plan(system, Ana::PlanInput.new("Projet")).value!
  sale = Ana.create_post(system, Ana::PostInput.new(activity.id, "vente", "Ventes")).value!
  workshop = Ana.create_post(system, Ana::PostInput.new(activity.id, "atelier", "Atelier")).value!
  p1 = Ana.create_post(system, Ana::PostInput.new(project.id, "p1", "Projet 1")).value!
  RulesSetup.new(browser, activity, project, sale, workshop, p1)
end

# Charge de `amount` au 603 (journal O01, 15 mars 2026), contrepartie 101.
private def expense(amount : String = "100", day : String = "2026-03-15") : Acc::EntryView
  input = Acc::EntryInput.new(ledger_id: Books.ledger("O01").id, date: Books.date(day), lines: [
    Acc::EntryLineInput.new("603", Acc::Side::Debit, Books.d(amount), nil, ""),
    Acc::EntryLineInput.new("101", Acc::Side::Credit, Books.d(amount), nil, ""),
  ])
  Acc.post_entry(Books.system, input).value!
end

private def distribute(entry : Acc::EntryView, post : Ana::PostView) : Nil
  Ana.distribute_entry(Books.system, entry.id, [Ana::LineDistributionInput.new(entry.lines[0].id,
    [Ana::DistributionRowInput.new(entry.lines[0].amount, [post.id])])]).value!
end

private def reader_browser(permissions : Array(String)) : PartiduoUi::Browser
  profile = PartiduoUi::Accounts.profile("Profil restreint", permissions)
  PartiduoUi::Accounts.create("bob@example.com", profile_id: profile)
  PartiduoUi::Accounts.signed_in("bob@example.com")
end

describe "Analytique : écrans, cas limites (lot 5)" do
  it "ne change pas la saisie tant qu'aucun plan n'existe, même module actif" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "ANALYTIC").success?.should be_true
    browser.get("/accounting/entries/misc").html.should_not contain("pd-col-analytic")
    browser.get("/analytic/plans").status.should eq(200)
  end

  it "répond 404 aux identifiants inconnus" do
    setup = rules_books
    %w[/analytic/plans/999999 /analytic/posts/999999 /analytic/keys/999999 /analytic/misc/999999
      /analytic/entries/999999].each do |path|
      setup.browser.get(path).status.should eq(404)
    end
  end

  it "réserve la ventilation, les opérations diverses, les clés et les paramètres aux droits d'écriture" do
    setup = rules_books
    entry = expense
    reader = reader_browser(%w[analytic.plan.read analytic.report.read accounting.entry.read])
    reader.get("/analytic/entries/#{entry.id}").status.should eq(403)
    reader.post("/analytic/entries/#{entry.id}", {"lines-0-rows-0-amount" => "100"}).status.should eq(403)
    reader.get("/analytic/misc/new").status.should eq(403)
    reader.get("/analytic/keys/new").status.should eq(403)
    reader.get("/analytic/settings").status.should eq(403)
    reader.post("/analytic/settings", {"mode" => "optional", "account_filter" => ""}).status.should eq(403)
    reader.post("/analytic/posts/#{setup.sale.id}/delete").status.should eq(403)
    Ana.posts(Books.system).size.should eq(3)
    Ana.entry_distributions(Books.system, entry.id).should be_empty
    reader.get("/analytic/keys").status.should eq(200)
  end

  it "ventile après coup par une clé du journal, puis retire la ventilation" do
    setup = rules_books
    entry = expense("90")
    key = Ana.create_key(Books.system, Ana::KeyInput.new("Tiers", [
      Ana::KeyRowInput.new(Books.d("50"), [setup.sale.id, setup.p1.id]),
      Ana::KeyRowInput.new(Books.d("50"), [setup.workshop.id]),
    ], "", [Books.ledger("O01").id])).value!
    form = setup.browser.get("/analytic/entries/#{entry.id}").html
    form.should contain(%(name="lines-0-key"))
    form.should contain("Tiers")

    setup.browser.post("/analytic/entries/#{entry.id}", {"lines-0-key" => key.id.to_s}).status.should eq(302)
    rows = Ana.entry_distributions(Books.system, entry.id).first.rows
    rows.map(&.amount).should eq([Books.d("45"), Books.d("45")])
    rows.first.posts.map(&.code).sort!.should eq(%w[P1 VENTE])

    setup.browser.post("/analytic/entries/#{entry.id}", {"lines-0-rows-0-amount" => ""}).status.should eq(302)
    Ana.entry_distributions(Books.system, entry.id).should be_empty
  end

  it "refuse de retirer la ventilation en mode obligatoire" do
    setup = rules_books
    entry = expense
    distribute(entry, setup.sale)
    Ana.update_settings(Books.system, Ana::SettingsInput.new(true, "6")).value!
    refused = setup.browser.post("/analytic/entries/#{entry.id}", {"lines-0-rows-0-amount" => ""})
    refused.status.should eq(422)
    Ana.entry_distributions(Books.system, entry.id).size.should eq(1)
  end

  it "signale le refus de supprimer un poste imputé dans une période close" do
    setup = rules_books
    entry = expense
    distribute(entry, setup.sale)
    period = Partiduo::Api::Core.period_for(Books.system, Books.date("2026-03-15")) || raise "période absente"
    Partiduo::Api::Core.close_period(Books.system, period.id).value!
    response = setup.browser.post("/analytic/posts/#{setup.sale.id}/delete")
    response.status.should eq(302)
    response.headers["Location"].should eq("/analytic/posts/#{setup.sale.id}")
    Ana.post(Books.system, setup.sale.id).code.should eq("VENTE")
    refused = setup.browser.post("/analytic/entries/#{entry.id}", {
      "lines-0-rows-0-amount" => "", "lines-0-rows-0-p#{setup.activity.id}" => setup.workshop.id.to_s,
    })
    refused.status.should eq(422)
    Ana.entry_distributions(Books.system, entry.id).first.rows.first.posts.map(&.code).should eq(["VENTE"])
  end

  it "échappe les libellés saisis dans les pages" do
    setup = rules_books
    Ana.update_post(Books.system, setup.sale.id,
      Ana::PostInput.new(setup.activity.id, "VENTE", "<script>alert(1)</script>")).value!
    # Contenu brut : `html` décode les entités.
    page = setup.browser.get("/analytic/plans/#{setup.activity.id}").content
    page.should_not contain("<script>alert(1)</script>")
    page.should contain("&lt;script&gt;")
  end

  it "modifie et supprime une clé par les formulaires" do
    setup = rules_books
    key = Ana.create_key(Books.system, Ana::KeyInput.new("Pleine",
      [Ana::KeyRowInput.new(Books.d("100"), [setup.sale.id])])).value!
    setup.browser.get("/analytic/keys/#{key.id}/edit").html.should contain(%(value="Pleine"))
    bad = setup.browser.post("/analytic/keys/#{key.id}/edit", {
      "name" => "Pleine", "rows-0-percent" => "120", "rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
    })
    bad.status.should eq(422)
    setup.browser.post("/analytic/keys/#{key.id}/edit", {
      "name" => "Moitiés",
      "rows-0-percent" => "50", "rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
      "rows-1-percent" => "50", "rows-1-p#{setup.activity.id}" => setup.workshop.id.to_s,
    }).status.should eq(302)
    Ana.key(Books.system, key.id).rows.size.should eq(2)
    setup.browser.post("/analytic/keys/#{key.id}/delete").status.should eq(302)
    Ana.keys(Books.system).should be_empty
  end

  it "modifie une opération diverse ; refuse une date hors exercice" do
    setup = rules_books
    view = Ana.create_misc_operation(Books.system, Ana::MiscOperationInput.new(Books.date("2026-03-10"), "Transfert", [
      Ana::MiscRowInput.new(Books.d("30"), Acc::Side::Debit, [setup.sale.id]),
      Ana::MiscRowInput.new(Books.d("30"), Acc::Side::Credit, [setup.workshop.id]),
    ])).value!
    setup.browser.get("/analytic/misc/#{view.id}/edit").html.should contain("Transfert")
    values = {
      "date" => "2026-03-11", "description" => "Transfert corrigé",
      "rows-0-amount" => "40", "rows-0-side" => "debit", "rows-0-p#{setup.activity.id}" => setup.sale.id.to_s,
      "rows-1-amount" => "40", "rows-1-side" => "credit", "rows-1-p#{setup.activity.id}" => setup.workshop.id.to_s,
    }
    setup.browser.post("/analytic/misc/#{view.id}/edit", values).status.should eq(302)
    updated = Ana.misc_operation(Books.system, view.id)
    updated.description.should eq("Transfert corrigé")
    updated.rows.first.amount.should eq(Books.d("40"))
    setup.browser.post("/analytic/misc/#{view.id}/edit", values.merge({"date" => "2031-01-01"})).status.should eq(422)
    Ana.misc_operation(Books.system, view.id).date.should eq(Books.date("2026-03-11"))
  end

  it "exporte chaque édition en CSV" do
    setup = rules_books
    distribute(expense, setup.sale)
    range = "from=2026-01-01&to=2026-12-31"
    plan = setup.activity.id
    {
      "/analytic/reports/cross?f=1&plan=#{plan}&other_plan=#{setup.project.id}&#{range}",
      "/analytic/reports/groups?f=1&plan=#{plan}&#{range}",
      "/analytic/reports/history?f=1&plan=#{plan}&#{range}",
      "/analytic/reports/ledger?f=1&plan=#{plan}&#{range}",
      "/analytic/reports/table?f=1&plan=#{plan}&axis=account&#{range}",
    }.each do |path|
      response = setup.browser.get("#{path}&format=csv")
      response.status.should eq(200)
      response.content_type.should start_with("text/csv")
    end
    history = setup.browser.get("/analytic/reports/history?f=1&plan=#{plan}&#{range}&format=csv").content
    history.should contain("VENTE")
  end

  it "avertit quand des journaux invisibles sont écartés d'une édition" do
    setup = rules_books
    distribute(expense, setup.sale)
    reader = reader_browser(%w[analytic.plan.read analytic.report.read accounting.entry.read])
    user = Partiduo::Api::Auth.users(Books.system).find! { |item| item.email == "bob@example.com" }
    Partiduo::Api::Auth.set_ledger_security(Books.system, user.id, true).value!
    page = reader.get("/analytic/reports?f=1&plan=#{setup.activity.id}&from=2026-01-01&to=2026-12-31").html
    page.should contain("Des imputations de journaux que vous ne pouvez pas consulter sont écartées.")
    page.should_not contain("100,00")
  end
end

describe "Analytique : relecture du lot 5 (écrans)" do
  it "ventile la ligne saisie désignée par son rang, quelle que soit sa place dans l'écriture" do
    setup = rules_books
    supplier = Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    # Ligne 0 nulle (écartée par le cœur) : la ventilation de la ligne 1
    # ne glisse pas sur une autre ligne de l'écriture.
    values = {"ledger_id" => Books.ledger("A01").id.to_s, "date" => "2026-03-18", "third_party" => supplier.code,
              "label" => "Abonnement", "line-0-account" => "604", "line-0-amount" => "0", "line-0-vat_rate" => "NOR",
              "line-1-account" => "603", "line-1-amount" => "72", "line-1-vat_rate" => "NOR",
              "line-1-ana-p#{setup.activity.id}" => setup.sale.id.to_s}
    setup.browser.post("/accounting/entries/purchase", values).status.should eq(302)
    entry = Acc.entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("A01").id)).first
    distributions = Ana.entry_distributions(Books.system, entry.id)
    distributions.map { |item| {item.account_number, item.rows.first.amount} }.should eq([{"603", Books.d("72")}])
  end

  it "avertit en mode obligatoire celui qui saisit sans pouvoir ventiler" do
    setup = rules_books
    Ana.update_settings(Books.system, Ana::SettingsInput.new(true, "6")).value!
    profile = PartiduoUi::Accounts.profile("Saisie", ["accounting.entry.post", "accounting.entry.read", "accounting.ledger.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile_id: profile)
    clerk = PartiduoUi::Accounts.signed_in("bob@example.com")
    page = clerk.get("/accounting/entries/misc").html
    page.should contain("pd-entry-analytic-warning")
    page.should_not contain("/analytic/reports/undistributed")
    setup.browser.get("/accounting/entries/misc").html.should_not contain("pd-entry-analytic-warning")
    setup.browser.get("/accounting/entries/financial").html.should contain("/analytic/reports/undistributed")
  end

  it "fige la ventilation d'une écriture annulée et de son extourne" do
    setup = rules_books
    entry = expense
    distribute(entry, setup.sale)
    reversal = Acc.cancel_entry(Books.system, Acc::CancelEntryInput.new(entry.id)).value!
    [entry.id, reversal.id].each do |id|
      setup.browser.get("/accounting/entries/#{id}").html.should_not contain("/analytic/entries/#{id}")
      setup.browser.get("/analytic/entries/#{id}").status.should eq(302)
    end
  end

  it "ouvre l'écran de ventilation à qui peut ventiler sans lire les éditions" do
    rules_books
    entry = expense
    writer = reader_browser(%w[analytic.plan.read analytic.operation.write accounting.entry.read accounting.entry.post])
    writer.get("/analytic/entries/#{entry.id}").status.should eq(200)
  end

  it "présente les montants des erreurs du contrat selon la langue" do
    error = Partiduo::Api::FieldError.base("analytic.errors.distribution.exceeds",
      {"plan" => "ACTIVITE", "total" => "1250.50", "amount" => "100.00"})
    message = PartiduoUi::Format.new("fr").message(error)
    message.should contain("1\u202F250,50")
    message.should contain("100,00")
  end
end
