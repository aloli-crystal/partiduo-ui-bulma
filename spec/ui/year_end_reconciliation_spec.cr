# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Fin d'exercice (D-UI-053) et rapprochement bancaire (D-UI-054).

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private NNBSP = "\u202F"

private def system
  Partiduo::Api::Actor.system
end

private def year(value : Int32) : Partiduo::Api::Core::FiscalYearView
  Partiduo::Api::Core.fiscal_years(system).find! { |item| item.year == value }
end

private def misc(lines : Array(Acc::EntryLineInput), day : String) : Acc::EntryView
  Acc.post_entry(system, Acc::EntryInput.new(ledger_id: Books.ledger("O01").id, date: Books.date(day), lines: lines)).value!
end

private def line(account : String, side : Acc::Side, amount : String) : Acc::EntryLineInput
  Acc::EntryLineInput.new(account, side, Books.d(amount))
end

describe "Fin d'exercice (clôture et à-nouveaux)" do
  it "propose la clôture, signale le compte de résultat absent, puis la passe" do
    browser = Books.admin
    # 120 est au plan FR initial (D-CLO-003) : retiré, comme dans une
    # instance antérieure à l'amendement.
    Acc.delete_account(system, Acc.account(system, "120").id).success?.should be_true
    misc([line("510001", Acc::Side::Debit, "1500"), line("706", Acc::Side::Credit, "1500")], "2026-06-10")
    page = browser.get("/accounting/closing?fiscal_year=#{year(2026).id}&kind=closing").html
    page.should contain("<h1>Clôture</h1>")
    page.should contain("Clôture de l'exercice 2026 au 31/12/2026")
    page.should contain("Bénéfice : 1#{NNBSP}500,00")
    page.should contain("Le compte 120 n'existe pas dans le plan comptable")
    page.should contain(%(name="ledger_id"))

    refused = browser.post("/accounting/closing", {"fiscal_year" => year(2026).id.to_s, "kind" => "closing",
                                                   "ledger_id" => Books.ledger("O01").id.to_s})
    refused.status.should eq(422)
    refused.html.should contain("120")

    Acc.create_account(system, Acc::AccountInput.new("120", "Résultat de l'exercice (bénéfice)", "12"))
    posted = browser.post("/accounting/closing", {"fiscal_year" => year(2026).id.to_s, "kind" => "closing",
                                                  "ledger_id" => Books.ledger("O01").id.to_s})
    posted.status.should eq(302)
    entry = browser.follow(posted).html
    entry.should contain("Écriture de clôture")
    again = browser.get("/accounting/closing?fiscal_year=#{year(2026).id}&kind=closing").html
    again.should contain("Cette écriture est déjà passée")
    again.should_not contain(%(name="ledger_id"))
  end

  it "reporte les soldes de l'exercice précédent au premier jour" do
    browser = Books.admin
    PartiduoUi::Reference.fiscal_year(2027)
    misc([line("510001", Acc::Side::Debit, "800"), line("101", Acc::Side::Credit, "800")], "2026-02-01")
    page = browser.get("/accounting/closing?fiscal_year=#{year(2027).id}&kind=opening").html
    page.should contain("À-nouveaux de l'exercice 2027 au 01/01/2027")
    page.should contain("510001")
    posted = browser.post("/accounting/closing", {"fiscal_year" => year(2027).id.to_s, "kind" => "opening",
                                                  "ledger_id" => Books.ledger("O01").id.to_s, "label" => "Report 2026"})
    posted.status.should eq(302)
    id = PartiduoUi::Reference.id_from(posted.headers["Location"])
    Acc.entry(system, id).label.should eq("Report 2026")
    Acc.entry(system, id).date.should eq(Books.date("2027-01-01"))
  end

  it "est réservée au droit de clôturer" do
    PartiduoUi::Reference.provision
    profile = PartiduoUi::Accounts.profile("Lecteur", ["accounting.entry.read", "accounting.ledger.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/accounting/closing").status.should eq(403)
  end
end

describe "Rapprochement bancaire" do
  it "coche les opérations d'un relevé, contrôle l'écart et rapproche" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Client Morel")
    first = Books.receipt(customer.code, "1200", "2026-03-20").first
    second = Books.receipt(customer.code, "300", "2026-03-22").first
    f01 = Books.ledger("F01").id
    page = browser.get("/accounting/reconciliation?ledger=#{f01}").html
    page.should contain("Opérations à rapprocher")
    page.should contain(%(name="entry" value="#{first.id}"))
    page.should contain("1#{NNBSP}500,00") # solde non rapproché

    check = browser.htmx_post("/accounting/reconciliation/check", {"ledger" => f01.to_s, "entry" => first.id.to_s,
                                                                   "start_balance" => "0", "end_balance" => "1 500"})
    check.html.should contain("Écart entre le relevé et la sélection.")

    refused = browser.perform_raw("/accounting/reconciliation",
      "ledger=#{f01}&reference=R-03&start_balance=0&end_balance=1500&entry=#{first.id}")
    refused.status.should eq(422)
    refused.html.should contain("D'après le relevé, 1#{NNBSP}500,00 devraient être rapprochés")

    done = browser.perform_raw("/accounting/reconciliation",
      "ledger=#{f01}&reference=R-03&start_balance=0&end_balance=1500&entry=#{first.id}&entry=#{second.id}")
    done.status.should eq(302)
    after = browser.follow(done).html
    after.should contain("Relevé R-03 rapproché : 2 opérations, 1#{NNBSP}500,00.")
    after.should contain("Toutes les opérations de ce journal sont rapprochées.")
    statement = Acc.bank_statements(system, f01).first
    detail = browser.get("/accounting/reconciliation/statements/#{statement.id}").html
    detail.should contain("Relevé R-03")
    browser.post("/accounting/reconciliation/statements/#{statement.id}/delete").status.should eq(302)
    Acc.reconciliation(system, f01).unreconciled.size.should eq(2)
  end
end
