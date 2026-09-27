# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 2F — écrans de saisie et de consultation, cas limites : vente et
# avoir saisis à l'écran, nombre ou date illisibles, refus du contrat rangé
# sous la bonne ligne quand une ligne vide précède, date abrégée, journaux
# fermés en écriture, extourne refusée, lettrage refusé, relevé filtré.

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private def misc(values : Hash(String, String)) : Hash(String, String)
  {"ledger_id" => Books.ledger("O01").id.to_s, "date" => "2026-03-15", "receipt" => "", "label" => "OD"}.merge(values)
end

private def sale_values(customer : String, amount : String, extra = {} of String => String) : Hash(String, String)
  {"ledger_id" => Books.ledger("V01").id.to_s, "date" => "2026-03-18", "third_party" => customer, "due_date" => "",
   "label" => "Vente comptoir", "line-0-account" => "706", "line-0-amount" => amount, "line-0-vat_rate" => "NOR"}.merge(extra)
end

describe "Saisie d'une écriture — cas limites (lot 2F)" do
  it "enregistre une vente, puis un avoir saisi en montant négatif" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    page = browser.get("/accounting/entries/sale").html
    page.should contain(%(hx-get="/cards/complete?kind=customer"))

    response = browser.post("/accounting/entries/sale", sale_values(customer.code, "100"))
    response.status.should eq(302)
    credit = browser.post("/accounting/entries/sale", sale_values(customer.code, "-40"))
    credit.status.should eq(302)
    entries = Acc.entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("V01").id))
    entries.map(&.amount).should eq([Books.d("120.00"), Books.d("48.00")])
    Books.line_of(entries[1], customer.code).side.credit?.should be_true
  end

  it "refuse un montant illisible sans rien enregistrer" do
    browser = Books.admin
    response = browser.post("/accounting/entries/misc",
      misc({"line-0-account" => "510001", "line-0-debit" => "douze", "line-1-account" => "101", "line-1-credit" => "12"}))
    response.status.should eq(422)
    response.html.should contain(I18n.t("ui.forms.invalid_number"))
    response.html.should contain(%(aria-describedby="pd-l0-errors"))
    Acc.count_entries(Books.system).should eq(0)
  end

  it "range le refus du contrat sous la ligne saisie, même après une ligne vide" do
    browser = Books.admin
    response = browser.post("/accounting/entries/misc",
      misc({"line-0-account" => "", "line-0-debit" => "", "line-1-account" => "999999", "line-1-debit" => "10",
            "line-2-account" => "101", "line-2-credit" => "10"}))
    response.status.should eq(422)
    body = response.html
    body.should contain(%(aria-invalid="true" aria-describedby="pd-l1-errors"))
    body.should_not contain(%(aria-describedby="pd-l0-errors"))
    body.should_not contain(%(aria-describedby="pd-l2-errors"))
  end

  it "comprend une date abrégée (jour et mois) et refuse une date impossible" do
    browser = Books.admin
    response = browser.post("/accounting/entries/misc",
      misc({"date" => "1503", "line-0-account" => "510001", "line-0-debit" => "5", "line-1-account" => "101", "line-1-credit" => "5"}))
    response.status.should eq(302)
    Acc.entries(Books.system).first.date.should eq(Books.date("2026-03-15"))

    bad = browser.post("/accounting/entries/misc",
      misc({"date" => "31/02/2026", "line-0-account" => "510001", "line-0-debit" => "5", "line-1-account" => "101", "line-1-credit" => "5"}))
    bad.status.should eq(422)
    bad.html.should contain(I18n.t("ui.forms.invalid_date"))
    Acc.count_entries(Books.system).should eq(1)
  end

  it "refuse une date hors exercice avec la clé du contrat, traduite" do
    browser = Books.admin
    response = browser.post("/accounting/entries/misc",
      misc({"date" => "2031-01-15", "line-0-account" => "510001", "line-0-debit" => "5", "line-1-account" => "101", "line-1-credit" => "5"}))
    response.status.should eq(422)
    response.html.should_not contain("accounting.errors.entry.date.no_period")
    Acc.count_entries(Books.system).should eq(0)
  end

  it "prévient quand aucun journal du type n'est ouvert en écriture" do
    Books.admin
    profile = PartiduoUi::Accounts.profile("Saisie", ["accounting.entry.post", "accounting.entry.read", "accounting.ledger.read"])
    user = PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    Partiduo::Api::Auth.set_ledger_security(Books.system, user.user.id, true).value!
    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    page = bob.get("/accounting/entries/misc").html
    page.should contain(I18n.t("ui.entries.no_ledger"))
    bob.post("/accounting/entries/misc",
      misc({"line-0-account" => "510001", "line-0-debit" => "5", "line-1-account" => "101", "line-1-credit" => "5"}))
      .status.should eq(403)
    Acc.count_entries(Books.system).should eq(0)
  end
end

describe "Consultation et lettrage — cas limites (lot 2F)" do
  it "refuse l'extourne sans le droit (403), d'une écriture inconnue (404), en période close (message)" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    sale = Books.sale(customer.code, "100", "2026-02-10")
    browser.get("/accounting/entries/987654").status.should eq(404)
    browser.post("/accounting/entries/987654/cancel").status.should eq(404)

    period = Partiduo::Api::Core.period_for(Books.system, Books.date("2026-02-10")) || raise "période absente"
    Partiduo::Api::Core.close_period(Books.system, period.id).value!
    refused = browser.post("/accounting/entries/#{sale.id}/cancel")
    refused.status.should eq(302)
    browser.follow(refused).html.should contain("is-danger")
    Acc.entry(Books.system, sale.id).cancelled?.should be_false

    profile = PartiduoUi::Accounts.profile("Lecteur", ["accounting.entry.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    bob.get("/accounting/entries/#{sale.id}").html.should_not contain("/cancel")
    bob.post("/accounting/entries/#{sale.id}/cancel").status.should eq(403)
  end

  it "refuse de lettrer deux lignes d'un même côté, et laisse les lignes ouvertes" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    first = Books.sale(customer.code, "100")
    a = Books.line_of(first, customer.code)
    b = Books.line_of(Books.sale(customer.code, "50"), customer.code)
    browser.get("/accounting/matching?q=CLI-MOREL")
    refused = browser.perform_raw("/accounting/matching", "q=CLI-MOREL&line=#{a.id}&line=#{b.id}")
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("accounting.errors.matching.one_side"))
    refused.html.should contain(%(value="#{a.id}" id="pd-match-#{a.id}" checked))
    Acc.entry(Books.system, first.id).lines.all?(&.matching_id.nil?).should be_true

    browser.get("/accounting/matching?q=INCONNU").status.should eq(404)
    browser.get("/accounting/matching").status.should eq(200)
  end

  it "filtre le relevé sur les lignes ouvertes et sur une période" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    paid = Books.sale(customer.code, "10", "2026-01-10")
    Books.sale(customer.code, "50", "2026-03-10")
    payment = Books.receipt(customer.code, "12", "2026-01-15").first
    Acc.match_lines(Books.system, [Books.line_of(paid, customer.code).id, Books.line_of(payment, customer.code).id]).value!

    all = browser.get("/accounting/accounts?q=CLI-MOREL&from=2026-01-01").html
    all.should contain("10/01/2026")
    open = browser.get("/accounting/accounts?q=CLI-MOREL&from=2026-01-01&open=1").html
    open.should_not contain("10/01/2026")
    open.should contain("10/03/2026")
    window = browser.get("/accounting/accounts?q=CLI-MOREL&from=2026-03-01&to=2026-03-31").html
    window.should_not contain("15/01/2026")
    window.should contain("10/03/2026")
  end

  it "répond 404 à la consultation quand la Comptabilité est inactive" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
    browser.get("/accounting/entries").status.should eq(404)
    browser.get("/accounting/accounts?q=101").status.should eq(404)
    browser.get("/accounting/matching").status.should eq(404)
  end
end
