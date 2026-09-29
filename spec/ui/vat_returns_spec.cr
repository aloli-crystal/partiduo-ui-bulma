# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 4 — écrans des déclarations de TVA : préparation, déclaration
# enregistrée (correction, recalcul, clôture, liquidation), contrôle,
# historique, exports, paramètres (mandataire, règles de calcul).

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

# Critères d'une CA3 du premier trimestre 2026.
private CA3_Q1 = "form=fr_ca3&year=2026&periodicity=quarter&number=1&exigibility=operation"

# Dossier français : une vente de 100 HT au taux normal le 10 mars 2026.
private def french_books : PartiduoUi::Browser
  browser = Books.admin
  customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
  Books.sale(customer.code, "100", "2026-03-10")
  browser
end

# Brouillon de CA3 du premier trimestre, enregistré par l'écran.
private def saved_draft(browser : PartiduoUi::Browser) : Int64
  response = browser.post("/accounting/vat/returns/new?#{CA3_Q1}")
  response.status.should eq(302)
  location = response.headers["Location"]
  location.should match(%r{\A/accounting/vat/returns/\d+\z})
  PartiduoUi::Reference.id_from(location)
end

private def bob(*permissions : String) : PartiduoUi::Browser
  profile = PartiduoUi::Accounts.profile("Profil de Bob", permissions.to_a)
  PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
  PartiduoUi::Accounts.signed_in("bob@example.com")
end

describe "Déclarations de TVA (lot 4)" do
  it "détaille la ligne 14 dans l'annexe 3310-A (taux particuliers)" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Client Corse", "CLI-CORSE")
    input = Acc::DocumentInput.new(ledger_id: Books.ledger("V01").id, date: Books.date("2026-03-12"), third_party: customer.code,
      lines: [Acc::DocumentLineInput.new(amount: Books.d("1000"), account: "706", vat_rate: "COR13")], label: "Facture Corse")
    Acc.post_sale(Books.system, input).value!
    page = browser.get("/accounting/vat?f=1&#{CA3_Q1}").html
    page.should contain("Annexe 3310-A — taux particuliers (ligne 14)")
    page.should contain(%(id="pd-vat-annex"))
    page.should contain(">COR13<")
    page.should contain(">130,00<")
    id = saved_draft(browser)
    browser.get("/accounting/vat/returns/#{id}").html.should contain("Annexe 3310-A")
  end

  it "prépare une déclaration : critères, cases calculées sans rien enregistrer, bouton d'enregistrement" do
    browser = french_books
    empty = browser.get("/accounting/vat")
    empty.status.should eq(200)
    empty.html.should contain("<h1>Déclaration de TVA</h1>")
    empty.html.should contain(%(name="form"))
    empty.html.should contain(%(aria-current="page">Préparation</a>))

    page = browser.get("/accounting/vat?f=1&#{CA3_Q1}").html
    page.should contain("08.base")
    page.should contain(">100,00<")
    page.should contain(">20,00<")
    page.should contain("T1 2026")
    page.should contain(%(action="/accounting/vat/returns/new?form=fr_ca3&year=2026))
    Acc.vat_returns(Books.system).should be_empty
  end

  it "range sous leur champ les critères refusés" do
    browser = french_books
    bad_year = browser.get("/accounting/vat?f=1&form=fr_ca3&year=vingt&periodicity=quarter&number=1")
    bad_year.status.should eq(422)
    bad_year.html.should contain(I18n.t("ui.forms.invalid_integer"))
    refused = browser.get("/accounting/vat?f=1&form=fr_ca3&year=2026&periodicity=year&number=1")
    refused.status.should eq(422)
    refused.html.should contain(%(aria-invalid="true"))
  end

  it "enregistre le brouillon, l'affiche, le liste dans l'historique et l'exporte" do
    browser = french_books
    id = saved_draft(browser)
    show = browser.get("/accounting/vat/returns/#{id}")
    show.status.should eq(200)
    html = show.html
    html.should contain("Brouillon")
    html.should contain("Calculé")
    html.should contain("Déclaré")
    html.should contain(%(href="/accounting/vat/returns/#{id}/edit"))
    html.should contain(%(href="/accounting/vat/returns/#{id}/close"))
    html.should contain(%(href="/accounting/vat/returns/#{id}/control"))
    html.should contain(%(href="/accounting/vat/returns/#{id}/file?format=pdf"))
    html.should_not contain("format=xml")

    # Deuxième brouillon de la même période : refusé, message du contrat.
    again = browser.post("/accounting/vat/returns/new?#{CA3_Q1}")
    again.status.should eq(302)
    again.headers["Location"].should start_with("/accounting/vat?")

    history = browser.get("/accounting/vat/returns").html
    history.should contain(%(href="/accounting/vat/returns/#{id}"))
    history.should contain("Brouillon")
    csv = browser.get("/accounting/vat/returns?format=csv")
    csv.content_type.should start_with("text/csv")

    file = browser.get("/accounting/vat/returns/#{id}/file?format=csv")
    file.status.should eq(200)
    file.headers["Content-Disposition"].should contain("attachment")
    pdf = browser.get("/accounting/vat/returns/#{id}/file?format=pdf")
    pdf.content_type.should start_with("application/pdf")
    pdf.content.should start_with("%PDF-")
    browser.get("/accounting/vat/returns/#{id}/file?format=zip").status.should eq(404)
    # XML Intervat : formulaires belges seulement, refus du contrat en message.
    xml = browser.get("/accounting/vat/returns/#{id}/file?format=xml")
    xml.status.should eq(302)
  end

  it "corrige une case, la signale au contrôle, puis détecte les écritures passées depuis le calcul" do
    browser = french_books
    id = saved_draft(browser)
    form = browser.get("/accounting/vat/returns/#{id}/edit")
    form.status.should eq(200)
    form.html.should contain(%(name="box_08.base"))

    refused = browser.post("/accounting/vat/returns/#{id}/edit", {"box_08.base" => "cent"})
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("ui.forms.invalid_number"))

    saved = browser.post("/accounting/vat/returns/#{id}/edit", {"box_08.base" => "150"})
    saved.status.should eq(302)
    Acc.vat_return(Books.system, id).box("08.base").try(&.adjusted).should be_true
    browser.get("/accounting/vat/returns/#{id}").html.should contain("corrigée")

    control = browser.get("/accounting/vat/returns/#{id}/control").html
    control.should contain("Détail du calcul")
    control.should contain("Cases corrigées à la main : 08.base")
    control.should_not contain("Le calcul a changé")

    Books.sale("CLI-MOREL", "50", "2026-03-15")
    stale = browser.get("/accounting/vat/returns/#{id}/control").html
    stale.should contain("Le calcul a changé depuis l'enregistrement")
    stale.should contain(%(action="/accounting/vat/returns/#{id}/recompute"))

    browser.post("/accounting/vat/returns/#{id}/recompute").status.should eq(302)
    Acc.vat_return(Books.system, id).box("08.tax").try(&.computed).should eq(BigDecimal.new(30))
    browser.get("/accounting/vat/returns/#{id}/control").html.should_not contain("Le calcul a changé")

    # Case rendue au montant calculé.
    browser.post("/accounting/vat/returns/#{id}/edit", {"box_08.base" => ""}).status.should eq(302)
    Acc.vat_return(Books.system, id).box("08.base").try(&.adjusted).should be_false
  end

  it "clôt la déclaration avec l'écriture de liquidation ; une déclaration close est figée" do
    browser = french_books
    id = saved_draft(browser)
    form = browser.get("/accounting/vat/returns/#{id}/close").html
    form.should contain(%(name="settle"))
    form.should contain(%(name="payable_account"))

    refused = browser.post("/accounting/vat/returns/#{id}/close", {"settle" => "1", "date" => "31/02/2026"})
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("ui.forms.invalid_date"))

    closed = browser.post("/accounting/vat/returns/#{id}/close", {"settle" => "1", "date" => "", "ledger_id" => "",
                                                                  "payable_account" => "", "receivable_account" => ""})
    closed.status.should eq(302)
    view = Acc.vat_return(Books.system, id)
    view.closed?.should be_true
    entry = view.settlement_entry_id
    entry.should_not be_nil

    show = browser.get("/accounting/vat/returns/#{id}").html
    show.should contain("Close")
    show.should contain(%(href="/accounting/entries/#{entry}"))
    show.should_not contain("/accounting/vat/returns/#{id}/edit")
    show.should_not contain("/accounting/vat/returns/#{id}/delete")
    browser.get("/accounting/vat/returns/#{id}/edit").status.should eq(302)
    browser.post("/accounting/vat/returns/#{id}/delete").status.should eq(302)
    Acc.vat_return(Books.system, id).closed?.should be_true
  end

  it "clôt sans liquider, puis liquide depuis la déclaration close" do
    browser = french_books
    id = saved_draft(browser)
    browser.post("/accounting/vat/returns/#{id}/close", {"date" => ""}).status.should eq(302)
    view = Acc.vat_return(Books.system, id)
    view.closed?.should be_true
    view.settlement_entry_id.should be_nil
    browser.get("/accounting/vat/returns/#{id}").html.should contain(%(href="/accounting/vat/returns/#{id}/settle"))

    browser.get("/accounting/vat/returns/#{id}/settle").status.should eq(200)
    browser.post("/accounting/vat/returns/#{id}/settle", {"date" => ""}).status.should eq(302)
    Acc.vat_return(Books.system, id).settlement_entry_id.should_not be_nil
    browser.get("/accounting/vat/returns/#{id}").html.should_not contain("/settle")
  end

  it "supprime un brouillon" do
    browser = french_books
    id = saved_draft(browser)
    deleted = browser.post("/accounting/vat/returns/#{id}/delete")
    deleted.status.should eq(302)
    deleted.headers["Location"].should eq("/accounting/vat/returns")
    browser.get("/accounting/vat/returns/#{id}").status.should eq(404)
  end

  it "règle le mandataire et les règles de calcul d'une case" do
    browser = french_books
    settings = browser.get("/accounting/vat/settings")
    settings.status.should eq(200)
    settings.html.should contain("Règles de calcul — régime FR")
    settings.html.should contain(%(href="/accounting/vat/rules/fr/08.base"))
    settings.html.should contain(%(name="representative_name"))

    refused = browser.post("/accounting/vat/settings", {"representative_name" => "Fiduciaire Martin", "representative_id" => "",
                                                        "representative_issued_by" => "Belgique"})
    refused.status.should eq(422)
    refused.html.should contain(%(aria-invalid="true"))
    saved = browser.post("/accounting/vat/settings", {"representative_name" => "Fiduciaire Martin",
                                                      "representative_id" => "BE0417497106", "representative_issued_by" => "be"})
    saved.status.should eq(302)
    Acc.vat_settings(Books.system).representative_issued_by.should eq("BE")

    rules = browser.get("/accounting/vat/rules/fr/08.base")
    rules.status.should eq(200)
    rules.html.should contain(%(name="rules[0].source"))
    count = rules.html.scan(/name="rules\[\d+\]\.source"/).size

    # Toutes les règles retirées, une nouvelle saisie : seule celle-ci reste.
    data = {"count" => count.to_s}
    (0...count - 1).each { |index| data["rules[#{index}].remove"] = "1" }
    last = count - 1
    data["rules[#{last}].source"] = "base"
    data["rules[#{last}].ledger_kind"] = "sale"
    data["rules[#{last}].accounts"] = "706"
    browser.post("/accounting/vat/rules/fr/08.base", data).status.should eq(302)
    stored = Acc.vat_box_rules(Books.system, "fr").select(&.box.==("08.base"))
    stored.size.should eq(1)
    stored.first.accounts.should eq("706")
    browser.get("/accounting/vat/settings").html.should contain("/accounting/vat/reset-rules/fr")

    browser.post("/accounting/vat/reset-rules/fr").status.should eq(302)
    Acc.vat_box_rules(Books.system, "fr").all?(&.default).should be_true
  end

  it "propose le fichier Intervat d'une déclaration belge" do
    browser = Books.admin("be")
    customer = Books.card("CUSTOMER", "Brasserie Lambert", "CLI-LAMBERT")
    input = Acc::DocumentInput.new(ledger_id: Books.ledger("V01").id, date: Books.date("2026-02-10"), third_party: customer.code,
      lines: [Acc::DocumentLineInput.new(amount: Books.d("100"), account: "700", vat_rate: "21G")], label: "Facture")
    Acc.post_sale(Books.system, input).value!
    page = browser.get("/accounting/vat?f=1&form=be_periodic&year=2026&periodicity=quarter&number=1").html
    page.should contain(">100,00<")
    response = browser.post("/accounting/vat/returns/new?form=be_periodic&year=2026&periodicity=quarter&number=1")
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    browser.get("/accounting/vat/returns/#{id}").html.should contain(%(href="/accounting/vat/returns/#{id}/file?format=xml"))
    browser.get("/accounting/vat/returns/#{id}/edit").html.should contain(%(name="ask_restitution"))
    xml = browser.get("/accounting/vat/returns/#{id}/file?format=xml")
    xml.status.should eq(200)
    xml.content_type.should start_with("application/xml")
    xml.content.should contain("<?xml")
  end

  it "refuse les écrans sans accounting.vat.declare et répond 404 sans la Comptabilité" do
    Books.admin
    browser = bob("accounting.entry.read")
    {"/accounting/vat", "/accounting/vat/returns", "/accounting/vat/settings", "/accounting/vat/rules/fr/08.base"}.each do |path|
      {path, browser.get(path).status}.should eq({path, 403})
    end
    browser.get("/").html.should_not contain(%(href="/accounting/vat"))

    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
    PartiduoUi::Accounts.signed_in.get("/accounting/vat").status.should eq(404)
  end
end
