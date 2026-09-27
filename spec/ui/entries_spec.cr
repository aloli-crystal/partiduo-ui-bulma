# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private def csrf(browser : PartiduoUi::Browser, path : String) : String
  browser.get(path).html.match!(/name="csrf-token" content="([^"]+)"/)[1]
end

private def misc_lines(values : Hash(String, String)) : Hash(String, String)
  {"ledger_id" => Books.ledger("O01").id.to_s, "date" => "15", "receipt" => "", "label" => "Apport"}.merge(values)
end

describe "Saisie d'une écriture (ADR-005 D5)" do
  it "affiche le formulaire d'opérations diverses : journal, date du mois de la période, lignes, touches, contrôle" do
    browser = Books.admin
    page = browser.get("/accounting/entries/misc").html
    page.should contain("<h1>Opération diverse</h1>")
    page.should contain(%(data-pd-entry))
    page.should contain(%(<option value="#{Books.ledger("O01").id}" selected>O01 ·))
    page.should contain(%(name="line-0-account"))
    page.should contain(%(name="line-2-credit"))
    page.should contain(%(list="pd-dl-entry"))
    page.should contain(%(hx-get="/accounting/complete?list=entry"))
    page.should contain(%(hx-post="/accounting/entries/misc/check"))
    page.should contain("<kbd>Alt</kbd>+<kbd>↓</kbd> nouvelle ligne")
    page.should contain("ui/js/opal/entry.js")
    page.should contain(%(placeholder="O-00001"))
    # Menu : les quatre formes de saisie sont reliées.
    page.should contain(%(<a href="/accounting/entries/purchase">))
    page.should contain(%(<a href="/accounting/entries/financial">))
  end

  it "tient l'équilibre débit/crédit à jour par check_entry, même en-tête incomplet" do
    browser = Books.admin
    token = csrf(browser, "/accounting/entries/misc")
    headers = {"HX-Request" => "true", "X-CSRF-Token" => token}
    unbalanced = browser.post("/accounting/entries/misc/check",
      misc_lines({"date" => "", "line-0-account" => "510001", "line-0-debit" => "1 000,00", "line-1-account" => "101", "line-1-credit" => "400"}),
      headers).html
    unbalanced.should contain("1\u202F000,00")
    unbalanced.should contain("400,00")
    unbalanced.should contain(%(<span class="pd-state gap">Écart de 600,00</span>))

    balanced = browser.post("/accounting/entries/misc/check",
      misc_lines({"line-0-account" => "510001", "line-0-debit" => "1000", "line-1-account" => "101", "line-1-credit" => "1000"}),
      headers).html
    balanced.should contain(%(<span class="pd-state ok">Équilibrée</span>))
    # Date abrégée : le 15 du mois de la période de travail.
    month = Time.utc.year == 2026 ? Time.utc.month : 1
    balanced.should contain("Date : 15/#{month.to_s.rjust(2, '0')}/2026")
    balanced.should contain("Pièce : O-00001")
    balanced.should contain("Banque")
  end

  it "enregistre l'écriture, puis rouvre un formulaire vierge sur le même journal" do
    browser = Books.admin
    csrf(browser, "/accounting/entries/misc")
    response = browser.post("/accounting/entries/misc",
      misc_lines({"date" => "2026-03-15", "line-0-account" => "510001", "line-0-debit" => "1000", "line-0-label" => "Apport",
                  "line-1-account" => "101", "line-1-credit" => "1000", "line-2-account" => ""}))
    response.status.should eq(302)
    response.headers["Location"].should start_with("/accounting/entries/misc?ledger=")
    browser.follow(response).html.should contain("Écriture O-00001 enregistrée.")
    entry = Acc.entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("O01").id)).first
    entry.amount.should eq(Books.d("1000"))
    entry.date.should eq(Books.date("2026-03-15"))
    entry.lines.map(&.account_number).should eq(%w[510001 101])
  end

  it "refuse une écriture déséquilibrée et réaffiche la saisie avec le refus du contrat" do
    browser = Books.admin
    response = browser.post("/accounting/entries/misc",
      misc_lines({"date" => "2026-03-15", "line-0-account" => "510001", "line-0-debit" => "1000", "line-1-account" => "101", "line-1-credit" => "900"}))
    response.status.should eq(422)
    body = response.html
    body.should contain(%(value="1000"))
    body.should contain(%(value="900"))
    body.should contain("is-danger")
    Acc.count_entries(Books.system).should eq(0)

    both = browser.post("/accounting/entries/misc",
      misc_lines({"date" => "2026-03-15", "line-0-account" => "510001", "line-0-debit" => "10", "line-0-credit" => "10"}))
    both.status.should eq(422)
    both.html.should contain("Indiquez un montant au débit ou au crédit, pas les deux.")
    both.html.should contain(%(aria-invalid="true" aria-describedby="pd-l0-errors"))
  end

  it "ajoute et retire des lignes sans JavaScript, et en HTMX" do
    browser = Books.admin
    added = browser.post("/accounting/entries/misc", misc_lines({"line-0-account" => "101", "add_line" => "1"})).html
    added.should contain(%(name="line-1-account"))
    added.should contain(%(value="101"))

    removed = browser.post("/accounting/entries/misc",
      misc_lines({"line-0-account" => "101", "line-1-account" => "510001", "remove_line" => "0"})).html
    removed.should contain(%(name="line-0-account" id="pd-l0-account" value="510001"))
    removed.should_not contain(%(name="line-1-account"))

    row = browser.get("/accounting/entries/misc/line?line_next=7", {"HX-Request" => "true"}).html
    row.should contain(%(name="line-7-account"))
    row.should contain(%(id="pd-line-next" name="line_next" value="8" hx-swap-oob="true"))
  end

  it "saisit une facture d'achat : tiers complété, TVA ventilée par le contrat, pièce du journal" do
    browser = Books.admin
    supplier = Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    page = browser.get("/accounting/entries/purchase").html
    page.should contain("<h1>Écriture d'achat</h1>")
    page.should contain(%(hx-get="/cards/complete?kind=supplier"))
    page.should contain(%(<option value="NOR">NOR · 20\u202F%</option>))

    completion = browser.get("/cards/complete?kind=supplier&third_party=FOUR", {"HX-Request" => "true"}).html
    completion.should contain(%(<option value="FOUR-ORANGE">FOUR-ORANGE · Orange Business</option>))

    values = {"ledger_id" => Books.ledger("A01").id.to_s, "date" => "2026-03-18", "third_party" => supplier.code, "due_date" => "2026-04-17",
              "label" => "Abonnement fibre", "line-0-account" => "603", "line-0-amount" => "72", "line-0-vat_rate" => "NOR"}
    check = browser.post("/accounting/entries/purchase/check", values, {"HX-Request" => "true"}).html
    check.should contain("Total TTC")
    check.should contain("86,40")
    check.should contain("14,40")
    check.should contain(%(<span class="pd-state ok">Équilibrée</span>))

    response = browser.post("/accounting/entries/purchase", values)
    response.status.should eq(302)
    entry = Acc.entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("A01").id)).first
    entry.amount.should eq(Books.d("86.40"))
    entry.due_date.should eq(Books.date("2026-04-17"))
  end

  it "saisit un extrait financier : entrée et sortie, une écriture par ligne" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    values = {"ledger_id" => Books.ledger("F01").id.to_s, "date" => "2026-03-20",
              "line-0-account" => customer.code, "line-0-label" => "Règlement", "line-0-debit" => "120",
              "line-1-account" => "101", "line-1-credit" => "20"}
    check = browser.post("/accounting/entries/financial/check", values, {"HX-Request" => "true"}).html
    check.should contain(%(<span class="pd-state ok">Équilibrée</span>))
    check.should contain("510001 <span class=\"pd-muted\">Banque</span>")
    response = browser.post("/accounting/entries/financial", values)
    response.status.should eq(302)
    browser.follow(response).html.should contain("Écritures F-00001, F-00002 enregistrées.")
    Acc.count_entries(Books.system, Acc::EntryQuery.new(ledger_id: Books.ledger("F01").id)).should eq(2)
  end

  it "complète comptes et fiches dès le premier caractère" do
    browser = Books.admin
    Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    accounts = browser.get("/accounting/complete?list=entry&line-0-account=5", {"HX-Request" => "true"}).html
    accounts.should contain(%(<option value="510001">510001 · Banque</option>))
    cards = browser.get("/accounting/complete?list=entry&line-0-account=a", {"HX-Request" => "true"}).html
    cards.should contain(%(<option value="CLI-MOREL">CLI-MOREL · Atelier Morel</option>))
    browser.get("/accounting/complete?list=entry&q=", {"HX-Request" => "true"}).html.strip.should eq("")
  end

  it "refuse la saisie sans le droit (403) et quand la Comptabilité est inactive (404)" do
    PartiduoUi::Reference.provision
    profile = PartiduoUi::Accounts.profile("Lecteur", ["accounting.entry.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/accounting/entries/misc").status.should eq(403)
    browser.get("/").html.should_not contain(%(href="/accounting/entries/misc"))

    admin = PartiduoUi::Accounts.create("bob@example.com")
    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
    bob.get("/accounting/entries/misc").status.should eq(404)
    admin.should_not be_nil
  end
end

describe "Consultation : écritures, comptes et tiers (ADR-005 D9), lettrage" do
  it "liste les écritures et ouvre une écriture, puis l'annule par extourne" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    sale = Books.sale(customer.code, "100")
    list = browser.get("/accounting/entries?from=2026-01-01&to=2026-12-31").html
    list.should contain(%(<a class="pd-link" href="/accounting/entries/#{sale.id}">V-00001</a>))
    list.should contain("120,00")

    detail = browser.get("/accounting/entries/#{sale.id}").html
    detail.should contain("<h1>Écriture V-00001")
    detail.should contain(%(href="/accounting/accounts?q=CLI-MOREL"))
    detail.should contain("Annuler par extourne")

    response = browser.post("/accounting/entries/#{sale.id}/cancel")
    response.status.should eq(302)
    browser.follow(response).html.should contain("Écriture annulée par l'extourne V-00002.")
    Acc.entry(Books.system, sale.id).cancelled?.should be_true
  end

  it "affiche la synthèse, la balance âgée et les mouvements d'un tiers, et les exporte" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL", "compta@morel.test")
    Books.sale(customer.code, "100", "2026-01-10", "2026-01-20")
    Books.sale(customer.code, "50", "2026-03-10", "2099-12-31")
    page = browser.get("/accounting/accounts?q=CLI-MOREL&from=2026-01-01").html
    page.should contain("<h1>Atelier Morel</h1>")
    page.should contain("Reste à encaisser")
    page.should contain("180,00") # reste dû
    page.should contain("120,00") # échu
    page.should contain("Balance âgée")
    page.should contain("Plus de 60 j")
    page.should contain(%(class="pd-mono pd-hide-s pd-due-late">20/01/2026<span class="is-sr-only"> (échéance dépassée)</span>))
    page.should contain("compta@morel.test")
    page.should contain(%(class="amount pd-show-s"))
    page.should contain(%(href="/accounting/matching?q=CLI-MOREL"))
    page.should contain("Relancer")

    csv = browser.get("/accounting/accounts?q=CLI-MOREL&format=csv")
    csv.content_type.should contain("text/csv")
    csv.content.should contain("2026-01-10")
    csv.content.should contain("120,00")

    missing = browser.get("/accounting/accounts?q=INCONNU")
    missing.status.should eq(404)
    missing.html.should contain("Aucun compte ni tiers « INCONNU ».")

    browser.get("/accounting/accounts").html.should contain("Choisissez un compte ou un tiers")
    # Accès depuis la fiche du tiers (navigation transverse).
    browser.get("/cards/#{customer.id}").html.should contain(%(href="/accounting/accounts?q=CLI-MOREL"))
  end

  it "lettre une facture et son règlement, contrôle la sélection, puis délettre" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    sale = Books.sale(customer.code, "100")
    payment = Books.receipt(customer.code, "120").first
    invoice_line = Books.line_of(sale, customer.code)
    payment_line = Books.line_of(payment, customer.code)

    page = browser.get("/accounting/matching?q=CLI-MOREL").html
    page.should contain(%(name="line" value="#{invoice_line.id}"))
    page.should contain(%(name="line" value="#{payment_line.id}"))
    page.should contain(%(hx-post="/accounting/matching/check"))

    token = csrf(browser, "/accounting/matching?q=CLI-MOREL")
    check = browser.post("/accounting/matching/check", {"q" => "CLI-MOREL", "line" => invoice_line.id.to_s}, {"HX-Request" => "true", "X-CSRF-Token" => token}).html
    check.should contain("Cochez au moins deux lignes")

    body = "q=CLI-MOREL&line=#{invoice_line.id}&line=#{payment_line.id}"
    matched = browser.perform_raw("/accounting/matching", body)
    matched.status.should eq(302)
    browser.follow(matched).html.should contain("Lettrage A créé (2 lignes).")
    after = Acc.entry(Books.system, sale.id).lines.find! { |line| line.id == invoice_line.id }
    after.matching_code.should eq("A")

    page = browser.get("/accounting/matching?q=CLI-MOREL").html
    page.should contain("Toutes les lignes sont lettrées.")
    page.should contain("Délettrer A")
    undone = browser.post("/accounting/matching/#{after.matching_id}/unmatch", {"q" => "CLI-MOREL"})
    browser.follow(undone).html.should contain("Lettrage A défait.")
  end
end
