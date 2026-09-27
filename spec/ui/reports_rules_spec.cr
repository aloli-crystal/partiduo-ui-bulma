# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 3 — écrans des éditions, cas limites : droits (`accounting.report.read`
# et `.write`), journaux invisibles (FEC refusé), rapports inconnus,
# modification et suppression d'un rapport personnalisé.

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

REPORT_RULES_SCREENS = %w[trial-balance auxiliary-balance aged-balance general-ledger journals balance-sheet
  income-statement custom fec]

private def books_with_sales : {PartiduoUi::Browser, String}
  browser = Books.admin
  customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
  Books.sale(customer.code, "100", "2026-03-10", "2026-03-31")
  Books.receipt(customer.code, "60", "2026-03-20")
  {browser, customer.code}
end

private def report! : Acc::ReportDefinitionView
  Acc.create_report(Books.system, Acc::ReportDefinitionInput.new("Ventes",
    [Acc::ReportLineInput.new("Ventes", "[70%]")])).value!
end

# Utilisateur « bob » muni des seules permissions citées.
private def bob(*permissions : String) : {Int64, PartiduoUi::Browser}
  profile = PartiduoUi::Accounts.profile("Profil de Bob", permissions.to_a)
  user = PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
  {user.user.id, PartiduoUi::Accounts.signed_in("bob@example.com")}
end

describe "Éditions (lot 3) — droits et cas limites" do
  it "refuse chaque édition et ses exports sans accounting.report.read, et masque le menu" do
    books_with_sales
    report = report!
    _, browser = bob("accounting.entry.read", "accounting.ledger.read")
    REPORT_RULES_SCREENS.each do |path|
      {path, browser.get("/accounting/reports/#{path}").status}.should eq({path, 403})
    end
    {"trial-balance", "general-ledger", "journals"}.each do |path|
      {path, browser.get("/accounting/reports/#{path}?format=csv").status}.should eq({path, 403})
    end
    browser.get("/accounting/reports/custom/#{report.id}").status.should eq(403)
    browser.get("/accounting/reports/custom/#{report.id}?format=pdf").status.should eq(403)
    browser.get("/accounting/reports/fec?download=1").status.should eq(403)
    menu = browser.get("/").html
    REPORT_RULES_SCREENS.each { |path| menu.should_not contain(%(href="/accounting/reports/#{path}")) }
  end

  it "laisse lire les rapports sans permettre de les créer, modifier ou effacer" do
    books_with_sales
    report = report!
    _, browser = bob("accounting.report.read")
    list = browser.get("/accounting/reports/custom").html
    list.should contain(%(href="/accounting/reports/custom/#{report.id}">Ventes</a>))
    list.should_not contain("/accounting/reports/custom/new")
    list.should_not contain("/accounting/reports/custom/#{report.id}/edit")
    list.should_not contain("/accounting/reports/custom/#{report.id}/delete")
    shown = browser.get("/accounting/reports/custom/#{report.id}?from=2026-01-01&to=2026-12-31")
    shown.status.should eq(200)
    shown.html.should_not contain("/edit")

    browser.get("/accounting/reports/custom/new").status.should eq(403)
    browser.post("/accounting/reports/custom/new", {"name" => "Pirate", "lines[0].label" => "x", "lines[0].formula" => "1"})
      .status.should eq(403)
    browser.get("/accounting/reports/custom/#{report.id}/edit").status.should eq(403)
    browser.post("/accounting/reports/custom/#{report.id}/edit", {"name" => "Pirate", "lines[0].label" => "x", "lines[0].formula" => "1"})
      .status.should eq(403)
    browser.post("/accounting/reports/custom/#{report.id}/delete").status.should eq(403)
    Acc.reports(Books.system).map(&.name).should eq(%w[Ventes])
  end

  it "modifie puis efface un rapport ; un rapport inconnu donne 404" do
    browser, _ = books_with_sales
    report = report!
    form = browser.get("/accounting/reports/custom/#{report.id}/edit").html
    form.should contain(%(value="Ventes"))
    form.should contain(%(value="[70%]"))

    taken = Acc.create_report(Books.system, Acc::ReportDefinitionInput.new("Autre", [Acc::ReportLineInput.new("A", "1")])).value!
    refused = browser.post("/accounting/reports/custom/#{report.id}/edit",
      {"name" => "Autre", "lines[0].label" => "Ventes", "lines[0].formula" => "[70%]"})
    refused.status.should eq(422)
    refused.html.should contain(%(aria-invalid="true"))
    Acc.report(Books.system, report.id).name.should eq("Ventes")

    saved = browser.post("/accounting/reports/custom/#{report.id}/edit",
      {"name" => "Chiffre d'affaires", "lines[0].label" => "Ventes", "lines[0].formula" => "[70%-S]",
       "lines[1].label" => "", "lines[1].formula" => ""})
    saved.status.should eq(302)
    updated = Acc.report(Books.system, report.id)
    updated.name.should eq("Chiffre d'affaires")
    updated.lines.map(&.formula).should eq(["[70%-S]"])

    deleted = browser.post("/accounting/reports/custom/#{taken.id}/delete")
    deleted.status.should eq(302)
    browser.follow(deleted).html.should contain("Autre")
    Acc.reports(Books.system).map(&.id).should eq([report.id])

    browser.get("/accounting/reports/custom/987654").status.should eq(404)
    browser.get("/accounting/reports/custom/987654?format=csv").status.should eq(404)
    browser.get("/accounting/reports/custom/987654/edit").status.should eq(404)
    browser.post("/accounting/reports/custom/987654/delete").status.should eq(404)
  end

  it "refuse le FEC à qui ne voit pas tous les journaux, message sous le formulaire" do
    books_with_sales
    user_id, browser = bob("accounting.report.read", "accounting.ledger.read")
    Partiduo::Api::Auth.set_ledger_security(Books.system, user_id, true).value!
    Partiduo::Api::Auth.set_ledger_access(Books.system, user_id, Books.ledger("O01").id, "R").value!
    year = Partiduo::Api::Core.fiscal_years(Books.system).first
    refused = browser.get("/accounting/reports/fec?fiscal_year=#{year.id}&separator=pipe&encoding=utf8&download=1")
    refused.status.should eq(422)
    refused.headers["Content-Disposition"]?.should be_nil
    refused.html.should contain(I18n.t("accounting.errors.fec.ledgers"))

    # Les autres éditions se limitent aux journaux visibles.
    journals = browser.get("/accounting/reports/journals?from=2026-01-01&to=2026-12-31").html
    journals.should_not contain("V01 ·")
    journals.should_not contain("CLI-MOREL")
  end

  it "donne 404 pour un exercice inconnu du FEC" do
    browser, _ = books_with_sales
    browser.get("/accounting/reports/fec?fiscal_year=987654&download=1").status.should eq(404)
  end

  it "fait disparaître les éditions quand la Comptabilité est inactive (404)" do
    browser, _ = books_with_sales
    report = report!
    previous = ENV["PARTIDUO_MODULES"]?
    ENV["PARTIDUO_MODULES"] = "invoicing"
    begin
      REPORT_RULES_SCREENS.each do |path|
        {path, browser.get("/accounting/reports/#{path}").status}.should eq({path, 404})
      end
      browser.get("/accounting/reports/custom/#{report.id}?format=csv").status.should eq(404)
      browser.post("/accounting/reports/custom/#{report.id}/delete").status.should eq(404)
    ensure
      previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
    end
    Acc.reports(Books.system).size.should eq(1)
  end
end
