# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 3 — écrans des éditions : balances, grand livre, journaux, bilan,
# compte de résultat, rapports personnalisés, FEC ; filtres persistants,
# exports CSV et PDF du cœur, navigation transverse.

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

# Dossier de démonstration : une vente de 100 HT au client CLI-MOREL
# (120 TTC, échue au 31 mars), encaissée à moitié.
private def books_with_sales : {PartiduoUi::Browser, String}
  browser = Books.admin
  customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
  Books.sale(customer.code, "100", "2026-03-10", "2026-03-31")
  Books.receipt(customer.code, "60", "2026-03-20")
  {browser, customer.code}
end

private def customer_account(code : String) : String
  Acc.account_statement(Books.system, Acc::StatementQuery.new(card: code)).account.try(&.number) || raise "compte du tiers introuvable"
end

describe "Éditions (lot 3)" do
  it "affiche la balance générale : comptes et montants reliés à leur consultation, totaux, exports" do
    browser, code = books_with_sales
    account = customer_account(code)
    page = browser.get("/accounting/reports/trial-balance?from=2026-01-01&to=2026-12-31").html
    page.should contain("<h1>Balance</h1>")
    # Compte → relevé ; mouvements → grand livre du compte sur la période.
    page.should contain(%(href="/accounting/accounts?q=#{account}&from=2026-01-01&to=2026-12-31"))
    page.should contain(%(href="/accounting/reports/general-ledger?account_from=706&account_to=706&from=2026-01-01&to=2026-12-31">100,00</a>))
    page.should contain("Total général")
    page.should contain("Totaux par classe")
    page.should contain(%(href="/accounting/reports/trial-balance?from=2026-01-01&to=2026-12-31&format=pdf"))
    page.should_not contain("ne sont pas équilibrés")

    csv = browser.get("/accounting/reports/trial-balance?from=2026-01-01&to=2026-12-31&format=csv")
    csv.status.should eq(200)
    csv.content_type.should start_with("text/csv")
    csv.headers["Content-Disposition"].should contain("attachment")
    csv.content.should contain("706")

    pdf = browser.get("/accounting/reports/trial-balance?from=2026-01-01&to=2026-12-31&format=pdf")
    pdf.status.should eq(200)
    pdf.content_type.should start_with("application/pdf")
    pdf.content.should start_with("%PDF-")
  end

  it "garde les critères de chaque édition et les ramène à la visite suivante" do
    browser, _ = books_with_sales
    first = browser.get("/accounting/reports/trial-balance?f=1&from=01%2F01%2F2026&account_from=7&account_to=7")
    first.status.should eq(200)
    first.html.should contain(%(value="7"))
    first.html.should_not contain(%(account_from=4))
    browser.cookie("partiduo_f_trial_balance").should_not be_nil

    back = browser.get("/accounting/reports/trial-balance")
    back.status.should eq(302)
    back.headers["Location"].should eq("/accounting/reports/trial-balance?from=01%2F01%2F2026&account_from=7&account_to=7&f=1")
    # Écran distinct : critères distincts.
    browser.get("/accounting/reports/general-ledger").status.should eq(200)

    # Case décochée et champs effacés : un choix gardé, pas un retour aux défauts.
    browser.get("/accounting/reports/trial-balance?f=1").status.should eq(200)
    browser.get("/accounting/reports/trial-balance").headers["Location"].should eq("/accounting/reports/trial-balance?f=1")

    reset = browser.get("/accounting/reports/trial-balance?reset=1")
    reset.status.should eq(302)
    reset.headers["Location"].should eq("/accounting/reports/trial-balance")
    browser.cookie("partiduo_f_trial_balance").should be_nil
    browser.get("/accounting/reports/trial-balance").status.should eq(200)
  end

  it "signale une date illisible sous son critère" do
    browser, _ = books_with_sales
    page = browser.get("/accounting/reports/trial-balance?f=1&from=31%2F02%2F2026").html
    page.should contain(I18n.t("ui.forms.invalid_date"))
    page.should contain(%(aria-invalid="true"))
  end

  it "affiche la balance des tiers : tiers → relevé, mouvements → grand livre auxiliaire" do
    browser, code = books_with_sales
    page = browser.get("/accounting/reports/auxiliary-balance?from=2026-01-01&to=2026-12-31&kind=customer").html
    page.should contain("Atelier Morel")
    page.should contain(%(href="/accounting/accounts?q=#{code}&from=2026-01-01&to=2026-12-31">#{code}</a>))
    page.should contain(%(href="/accounting/reports/general-ledger?by_card=1&card=#{code}&from=2026-01-01&to=2026-12-31">120,00</a>))
    page.should contain(%(>60,00</a>))
    browser.get("/accounting/reports/auxiliary-balance?kind=customer&format=csv").content.should contain(code)
  end

  it "affiche la balance âgée et le détail des éléments ouverts d'un tiers" do
    browser, code = books_with_sales
    page = browser.get("/accounting/reports/aged-balance?as_of=2026-06-30&kind=customer").html
    page.should contain("Balance âgée")
    page.should contain("Au 30/06/2026")
    page.should contain(%(href="/accounting/accounts?q=#{code}&open=1">60,00</a>))
    detail = browser.get("/accounting/reports/aged-balance?as_of=2026-06-30&kind=customer&card=#{code}").html
    detail.should contain("Éléments ouverts : Atelier Morel")
    detail.should contain(%(href="/accounting/entries/))

    missing = browser.get("/accounting/reports/aged-balance?card=INCONNU")
    missing.status.should eq(404)
    missing.html.should contain("INCONNU")
  end

  it "affiche le grand livre par compte et par tiers, chaque écriture reliée" do
    browser, code = books_with_sales
    account = customer_account(code)
    page = browser.get("/accounting/reports/general-ledger?from=2026-01-01&to=2026-12-31&account_from=#{account}&account_to=#{account}").html
    page.should contain("<h1>Grand livre</h1>")
    page.should contain("Solde d'ouverture")
    page.should contain("Solde de clôture")
    page.should contain(%(href="/accounting/entries/))
    page.should contain(%(>60,00</a>)) # solde de clôture → relevé
    page.should contain(%(href="/accounting/accounts?q=#{code}&from=2026-01-01&to=2026-12-31">#{code}</a>))

    by_card = browser.get("/accounting/reports/general-ledger?from=2026-01-01&to=2026-12-31&card=#{code}").html
    by_card.should contain("#{code} · Atelier Morel")
    browser.get("/accounting/reports/general-ledger?card=#{code}&format=pdf").content_type.should start_with("application/pdf")
  end

  it "affiche les journaux : écritures, lignes, totaux du mois" do
    browser, code = books_with_sales
    page = browser.get("/accounting/reports/journals?from=2026-03-01&to=2026-03-31").html
    page.should contain("<h1>Journaux</h1>")
    page.should contain("V01 ·")
    page.should contain("Facture #{code}")
    page.should contain(%(href="/accounting/entries/))
    page.should contain(%(href="/accounting/accounts?q=706&from=2026-03-01&to=2026-03-31">706 ·))
  end

  it "affiche le bilan et le compte de résultat, reliés l'un à l'autre" do
    browser, _ = books_with_sales
    sheet = browser.get("/accounting/reports/balance-sheet?from=2026-01-01&to=2026-12-31")
    sheet.status.should eq(200)
    body = sheet.html
    body.should contain("<h1>Bilan</h1>")
    body.should contain("Brut")
    body.should contain(%(href="/accounting/reports/income-statement?from=2026-01-01&to=2026-12-31">100,00</a>))

    income = browser.get("/accounting/reports/income-statement?from=2026-01-01&to=2026-12-31").html
    income.should contain("<h1>Compte de résultat</h1>")
    income.should contain(%(href="/accounting/reports/balance-sheet?from=2026-01-01&to=2026-12-31">100,00</a>))
    browser.get("/accounting/reports/income-statement?from=2026-01-01&to=2026-12-31&format=csv").status.should eq(200)
  end

  it "produit le FEC de l'exercice" do
    browser, _ = books_with_sales
    page = browser.get("/accounting/reports/fec").html
    page.should contain("Télécharger le FEC")
    page.should contain(%(name="separator"))
    year = Partiduo::Api::Core.fiscal_years(Books.system).first
    file = browser.get("/accounting/reports/fec?fiscal_year=#{year.id}&separator=pipe&encoding=utf8&download=1")
    file.status.should eq(200)
    file.headers["Content-Disposition"].should contain("FEC")
    file.content.should contain("JournalCode|JournalLib")
  end

  it "crée, calcule et exporte un rapport personnalisé" do
    browser, _ = books_with_sales
    browser.get("/accounting/reports/custom").html.should contain("Aucun rapport personnalisé.")
    browser.get("/accounting/reports/custom/new").html.should contain(%(name="lines[0].formula"))
    refused = browser.post("/accounting/reports/custom/new", {"name" => "Marge", "lines[0].label" => "Ventes", "lines[0].formula" => "[70%"})
    refused.status.should eq(422)
    refused.html.should contain(%(value="[70%"))

    response = browser.post("/accounting/reports/custom/new",
      {"name" => "Marge", "lines[0].label" => "", "lines[0].formula" => "", "lines[1].label" => "Ventes", "lines[1].formula" => "[70%]"})
    response.status.should eq(302)
    report = Acc.reports(Books.system).first
    report.lines.map(&.formula).should eq(["[70%]"])
    page = browser.follow(response).html
    page.should contain("Rapport « Marge » enregistré.")
    page.should contain(%(href="/accounting/reports/general-ledger?account_from=70&account_to=70))
    browser.get("/accounting/reports/custom/#{report.id}?format=csv").content.should contain("Ventes")
    browser.get("/accounting/reports/custom").html.should contain(%(href="/accounting/reports/custom/#{report.id}">Marge</a>))
  end

  it "affiche les soldes au plan comptable, reliés au relevé du compte" do
    browser, _ = books_with_sales
    page = browser.get("/accounting/chart?q=706").html
    page.should contain(">Solde</a>")
    page.should contain(%(href="/accounting/accounts?q=706&from=2026-01-01&to=))
  end

  it "garde aussi les critères de la liste des écritures" do
    browser, _ = books_with_sales
    browser.get("/accounting/entries?f=1&q=Facture").status.should eq(200)
    back = browser.get("/accounting/entries")
    back.status.should eq(302)
    back.headers["Location"].should eq("/accounting/entries?q=Facture&f=1")
    browser.get("/accounting/entries?f=1").html.should contain(%(name="f" value="1"))
  end

  it "relie les entrées du menu « Éditions »" do
    browser, _ = books_with_sales
    page = browser.get("/").html
    {"trial-balance", "auxiliary-balance", "aged-balance", "general-ledger", "journals", "balance-sheet", "income-statement", "custom", "fec"}.each do |path|
      page.should contain(%(href="/accounting/reports/#{path}"))
    end
  end

  it "rend les fichiers du cœur octet pour octet (FEC en ISO 8859-15, PDF)" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Œuvres d'été €", "CLI-OEUVRE")
    Books.sale(customer.code, "100", "2026-03-10", "2026-03-31")
    year = Partiduo::Api::Core.fiscal_years(Books.system).first
    expected = Acc.fec(Books.system, Acc::FecQuery.new(fiscal_year_id: year.id)).value!.content
    # €, Œ et é en ISO 8859-15 : 0xA4, 0xBC, 0xE9 (texte invalide en UTF-8).
    latin9 = Bytes[0xBC, 0x75, 0x76, 0x72, 0x65, 0x73, 0x20, 0x64, 0x27, 0xE9, 0x74, 0xE9, 0x20, 0xA4]
    (0..expected.size - latin9.size).any? { |offset| expected[offset, latin9.size] == latin9 }.should be_true
    fec = browser.get("/accounting/reports/fec?fiscal_year=#{year.id}&separator=pipe&encoding=latin9&download=1")
    fec.status.should eq(200)
    fec.content.to_slice.should eq(expected)

    pdf = browser.get("/accounting/reports/trial-balance?from=2026-01-01&to=2026-12-31&format=pdf")
    core = Acc.export(Books.system, Acc::TrialBalanceQuery.new(date_from: Time.utc(2026, 1, 1), date_to: Time.utc(2026, 12, 31)),
      Acc::ExportFormat::Pdf).content
    pdf.content.valid_encoding?.should be_false
    pdf.content.bytesize.should eq(core.size)
    pdf.content.to_slice[0, 15].should eq(core[0, 15])
  end
end
