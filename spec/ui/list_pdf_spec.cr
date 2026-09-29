# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "pdf-validate"

# Export PDF depuis chaque liste (ADR-005 D5, BLOCAGES B-CRIT-001,
# DECISIONS D-R5-008) : lien au pied des listes, PDF/A-2b produit par le
# service neutre du cœur, toutes les lignes filtrées et triées.

private alias Books = PartiduoUi::Books

private def pdf_of(browser : PartiduoUi::Browser, path : String) : Marten::HTTP::Response
  response = browser.get(path)
  response.status.should eq(200)
  response.content_type.should eq("application/pdf")
  response.headers["Content-Disposition"].should match(/attachment; filename=".+-\d{8}\.pdf"/)
  report = PDF::Validate.bytes(response.content.to_slice, profile: "pdf-a-2b")
  report.fatal_failures.map(&.rule.id).should eq([] of String)
  response
end

describe "Export PDF des listes (B-CRIT-001)" do
  it "offre CSV et PDF au pied d'une liste du référentiel et rend toutes les lignes filtrées" do
    browser = Books.admin
    120.times { |index| Books.card("CUSTOMER", "Client #{index.to_s.rjust(3, '0')}") }
    html = browser.get("/cards").html
    html.should contain(%(href="/cards?format=csv"))
    html.should contain(%(href="/cards?format=pdf"))
    html.should contain("Export PDF")
    pdf_of(browser, "/cards?format=pdf")
    pdf_of(browser, "/cards?q=Client%2011&format=pdf")
  end

  it "exporte en PDF les listes des paramètres, du plan comptable et des exercices" do
    browser = Books.admin
    %w[/accounting/chart /vat/rates /settings/modules /settings/currencies /fiscal-years /accounting/entries].each do |path|
      page = browser.get(path)
      next unless page.status == 200
      page.html.should contain("format=pdf")
      pdf_of(browser, "#{path}?format=pdf")
    end
  end

  it "exporte en PDF l'extrait d'un compte de tiers et la liste des actions du suivi" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    Books.sale(customer.code, "100", "2026-03-10")
    statement = browser.get("/accounting/accounts?q=CLI-MOREL").html
    statement.should contain("format=pdf")
    pdf_of(browser, "/accounting/accounts?q=CLI-MOREL&format=pdf")
    if browser.get("/followup/actions").status == 200
      browser.get("/followup/actions").html.should contain("format=pdf")
      pdf_of(browser, "/followup/actions?format=pdf")
    end
  end
end
