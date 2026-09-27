# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private NNBSP = " "

# Administrateur connecté sur un dossier provisionné (régime FR par défaut).
private def admin(regime : String = "fr") : PartiduoUi::Browser
  PartiduoUi::Reference.provision(regime)
  PartiduoUi::Accounts.create
  PartiduoUi::Accounts.signed_in
end

private def system
  Partiduo::Api::Actor.system
end

describe "Référentiel : menu et modules actifs (ADR-006)" do
  it "relie les entrées du référentiel et des paramètres à leurs écrans" do
    body = admin.get("/").html
    body.should contain(%(<a href="/accounting/chart"><span>Plan comptable</span></a>))
    body.should contain(%(<a href="/cards"><span>Tiers et articles</span></a>))
    body.should contain(%(<a href="/accounting/ledgers"><span>Journaux</span></a>))
    body.should contain(%(<a href="/vat/rates"><span>Taux de TVA</span></a>))
    body.should contain(%(<a href="/fiscal-years"><span>Exercices et périodes</span></a>))
  end

  it "masque les écrans de la Comptabilité inactive et les refuse (404)" do
    browser = admin
    Partiduo::Api::Modules.deactivate(system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(system, "ACCOUNTING").success?.should be_true
    body = browser.get("/").html
    body.should_not contain("Plan comptable")
    body.should_not contain(">Journaux<")
    body.should contain(%(<a href="/cards"><span>Tiers et articles</span></a>))
    browser.get("/accounting/chart").status.should eq(404)
    browser.get("/accounting/ledgers").status.should eq(404)
    browser.get("/accounting/ledgers/new").status.should eq(404)

    customer = PartiduoUi::Reference.category("CUSTOMER")
    card = Partiduo::Api::Cards.create_card(system, Partiduo::Api::Cards::CardInput.new(category_id: customer.id, name: "Morel")).value!
    card_page = browser.get("/cards/#{card.id}").html
    card_page.should contain("Morel")
    card_page.should_not contain("Comptabilité")
  end

  it "refuse les écrans de commande sans la permission" do
    PartiduoUi::Reference.provision
    profile = PartiduoUi::Accounts.profile("Lecteur", ["cards.card.read", "vat.rate.read", "accounting.account.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in
    list = browser.get("/cards").html
    list.should contain("<h1>Tiers</h1>")
    list.should_not contain("Nouveau tiers")
    browser.get("/cards/new").status.should eq(403)
    browser.get("/vat/rates/new").status.should eq(403)
    browser.get("/accounting/chart").html.should_not contain("Nouveau compte")
    browser.post("/accounting/chart/new", {"number" => "999", "label" => "Essai"}).status.should eq(403)
  end
end

describe "Exercices et périodes" do
  it "crée un exercice mensuel, le consulte et l'affiche dans la barre supérieure" do
    browser = admin
    page = browser.get("/fiscal-years").html
    page.should contain("<h1>Exercices et périodes</h1>")
    page.should contain("Aucun exercice")
    page.should contain(%(name="start_month"))

    response = browser.post("/fiscal-years", {"year" => "2026", "start_year" => "2026", "start_month" => "1", "months" => "12", "label" => ""})
    response.status.should eq(302)
    detail = browser.follow(response).html
    detail.should contain("Exercice 2026 créé.")
    detail.should contain("<h1>Exercice 2026")
    detail.should contain("janvier 2026")
    detail.should contain("décembre 2026")
    detail.should contain("01/01/2026")
    detail.should contain("31/12/2026")
    detail.scan("Clôturer</span>").size.should eq(12)

    # Barre supérieure : exercice et période de travail.
    top = browser.get("/").html
    top.should contain(%(<select id="pd-period" name="period" data-pd-autosubmit>))
    top.should contain(%(<optgroup label="2026">))
    top.should contain(">janvier 2026</option>")
  end

  it "refuse un exercice invalide, champ par champ" do
    browser = admin
    PartiduoUi::Reference.fiscal_year(2026)
    response = browser.post("/fiscal-years", {"year" => "2026", "start_year" => "2026", "start_month" => "1", "months" => "72"})
    response.status.should eq(422)
    body = response.html
    body.should contain("L'exercice 2026 existe déjà.")
    body.should contain("Le nombre de mois doit être compris entre 1 et 60.")
    body.should contain(%(aria-invalid="true"))

    refused = browser.post("/fiscal-years", {"year" => "deux mille", "start_year" => "2027", "start_month" => "1", "months" => "12"})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez un nombre entier.")
  end

  it "clôture et rouvre une période, puis clôture l'exercice" do
    browser = admin
    year = PartiduoUi::Reference.fiscal_year(2026)
    period = year.periods[2]
    response = browser.post("/periods/#{period.id}/close")
    response.headers["Location"].should eq("/fiscal-years/#{year.id}")
    browser.follow(response).html.should contain("Période mars 2026 clôturée.")
    Partiduo::Api::Core.period(system, period.id).closed?.should be_true

    browser.follow(browser.post("/periods/#{period.id}/reopen")).html.should contain("Période mars 2026 rouverte.")
    Partiduo::Api::Core.period(system, period.id).closed?.should be_false

    browser.follow(browser.post("/fiscal-years/#{year.id}/close")).html.should contain("Exercice 2026 clôturé.")
    Partiduo::Api::Core.fiscal_year(system, year.id).closed?.should be_true
    closed = browser.get("/fiscal-years/#{year.id}").html
    closed.should_not contain("Rouvrir")
    closed.should_not contain("Ajouter une période")
  end

  it "ajoute et supprime une période" do
    browser = admin
    year = Partiduo::Api::Core.create_fiscal_year(system, Partiduo::Api::Core::FiscalYearInput.new(year: 2027, start_year: 2027, months: 1)).value!
    response = browser.post("/fiscal-years/#{year.id}", {"starts_on" => "2027-02-01", "ends_on" => "2027-02-28"})
    browser.follow(response).html.should contain("Période février 2027 ajoutée.")
    overlap = browser.post("/fiscal-years/#{year.id}", {"starts_on" => "2027-02-15", "ends_on" => "2027-03-15"})
    overlap.status.should eq(422)
    overlap.html.should contain("chevauche")
    added = Partiduo::Api::Core.fiscal_year(system, year.id).periods.last
    browser.follow(browser.post("/periods/#{added.id}/delete")).html.should contain("Période février 2027 supprimée.")
  end

  it "retient la période de travail choisie dans la barre supérieure" do
    browser = admin
    year = PartiduoUi::Reference.fiscal_year(2026)
    june = year.periods[5]
    response = browser.post("/period", {"period" => june.id.to_s, "next" => "/cards"})
    response.headers["Location"].should eq("/cards")
    browser.get("/").html.should contain(%(<option value="#{june.id}" selected>juin 2026</option>))
    # Période inconnue : ignorée.
    browser.post("/period", {"period" => "999999", "next" => "/"})
    browser.get("/").html.should contain(%(<option value="#{june.id}" selected>))
  end
end

describe "Plan comptable" do
  it "affiche l'arbre par classe, filtre, trie et exporte" do
    browser = admin
    page = browser.get("/accounting/chart").html
    page.should contain("<h1>Plan comptable</h1>")
    page.should contain(%(<a href="/accounting/chart" aria-current="page">Toutes</a>))
    page.should contain(%(<a href="/accounting/chart?class=4">Classe 4</a>))
    page.should contain(%(class="pd-depth-0 pd-class))
    page.should_not contain(%(aria-sort="ascending"))

    class6 = browser.get("/accounting/chart?class=6").html
    class6.should contain(%(<a href="/accounting/chart?class=6" aria-current="page">Classe 6</a>))
    class6.should_not contain(">400</a>")
    class6.should contain(%(<input type="hidden" name="class" value="6">))

    filtered = browser.get("/accounting/chart?q=fournisseurs").html
    filtered.should contain(">400</a>")
    filtered.should_not contain(">510001</a>")

    sorted = browser.get("/accounting/chart?class=5&sort=-number").html
    sorted.should contain(%(aria-sort="descending"))
    numbers = sorted.scan(/>(5\d*)<\/a><\/td>/).map(&.[1])
    numbers.should eq(numbers.sort.reverse!)

    csv = browser.get("/accounting/chart?class=4&format=csv")
    csv.status.should eq(200)
    csv.content_type.should eq("text/csv; charset=utf-8")
    csv.headers["Content-Disposition"].should start_with(%(attachment; filename="plan-comptable-))
    csv.content.should start_with("﻿Compte;Libellé;Type;Saisie;Sous-comptes\n")
    csv.content.should contain("\n400;")
    csv.content.should_not contain("\n510001;")
  end

  it "crée, consulte, modifie et supprime un compte" do
    browser = admin
    refused = browser.post("/accounting/chart/new", {"number" => "", "label" => ""})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez le numéro du compte.")
    refused.html.should contain("Indiquez le libellé du compte.")

    response = browser.post("/accounting/chart/new", {"number" => "400100", "label" => "Fournisseurs de services", "direct_use" => "1"})
    response.status.should eq(302)
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    page = browser.follow(response).html
    page.should contain("Compte 400100 créé.")
    page.should contain("<h1>Compte 400100 — Fournisseurs de services")
    page.should contain(">400 — ")
    page.should contain("Aucun sous-compte.")

    parent = Partiduo::Api::Accounting.account(system, "400")
    parent_page = browser.get("/accounting/chart/#{parent.id}").html
    parent_page.should contain(">400100</a>")
    parent_page.should contain("Nouveau sous-compte")

    edit = browser.get("/accounting/chart/#{id}/edit").html
    edit.should contain(%(value="Fournisseurs de services"))
    browser.post("/accounting/chart/#{id}/edit", {"number" => "400100", "label" => "Prestataires", "parent" => "400", "kind" => "liability", "direct_use" => "1"})
    Partiduo::Api::Accounting.account_by_id(system, id).label.should eq("Prestataires")

    browser.follow(browser.post("/accounting/chart/#{parent.id}/delete")).html.should contain("Ce compte a des sous-comptes")
    browser.follow(browser.post("/accounting/chart/#{id}/delete")).html.should contain("Compte 400100 supprimé.")
  end
end

describe "Journaux" do
  it "liste, crée et consulte les journaux" do
    browser = admin
    page = browser.get("/accounting/ledgers").html
    page.should contain("<h1>Journaux</h1>")
    %w[A01 V01 F01 O01].each { |code| page.should contain(">#{code}</a>") }
    page.should contain("Écriture")

    sales = browser.get("/accounting/ledgers?kind=sale").html
    sales.should contain(">V01</a>")
    sales.should_not contain(">A01</a>")

    refused = browser.post("/accounting/ledgers/new", {"name" => "Banque 2", "kind" => "financial", "currency_code" => "EUR", "enabled" => "1"})
    refused.status.should eq(422)
    refused.html.should contain("Un journal financier a un compte de banque ou de caisse.")

    response = browser.post("/accounting/ledgers/new", {"name" => "Achats import", "kind" => "purchase", "currency_code" => "EUR",
                                                        "receipt_prefix" => "IMP-", "receipt_padding" => "4", "enabled" => "1"})
    response.status.should eq(302)
    ledger = browser.follow(response).html
    ledger.should contain("Journal Achats import créé.")
    ledger.should contain("IMP-0001")
  end
end

describe "Taux de TVA" do
  it "liste les taux du régime avec leur pourcentage" do
    browser = admin
    page = browser.get("/vat/rates").html
    page.should contain("<h1>Taux de TVA</h1>")
    page.should contain("20#{NNBSP}%")
    page.should contain("5,5#{NNBSP}%")
  end

  it "crée, modifie et désactive un taux" do
    browser = admin
    refused = browser.post("/vat/rates/new", {"code" => "X1", "label" => "Essai", "rate" => "dix", "category" => "S"})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez un nombre (par exemple 1 234,56).")
    refused.html.should contain(%(value="dix"))

    response = browser.post("/vat/rates/new", {"code" => "SP7", "label" => "TVA spéciale 7,5 %", "rate" => "7,5", "category" => "S", "enabled" => "1"})
    response.status.should eq(302)
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    browser.follow(response).html.should contain("7,5#{NNBSP}%")
    Partiduo::Api::Vat.rate(system, id).rate.should eq(BigDecimal.new("7.5"))

    browser.post("/vat/rates/#{id}/edit", {"code" => "SP7", "label" => "TVA spéciale", "rate" => "7,5", "category" => "S"})
    Partiduo::Api::Vat.rate(system, id).enabled.should be_false
    browser.get("/vat/rates").html.should_not contain(">SP7</a>")
    browser.get("/vat/rates?all=1").html.should contain(">SP7</a>")
  end
end

describe "Fiches : tiers, articles et services" do
  it "crée un client, le liste, le consulte avec son compte" do
    browser = admin
    customer = PartiduoUi::Reference.category("CUSTOMER")
    chooser = browser.get("/cards/new?for=parties").html
    chooser.should contain("<h1>Nouveau tiers</h1>")
    chooser.should contain("Choisissez une catégorie")

    form = browser.get("/cards/new?category=#{customer.id}").html
    form.should contain(%(name="siren"))
    form.should contain(%(name="address.city"))
    form.should_not contain(%(name="sale_price"))

    refused = browser.post("/cards/new", {"category_id" => customer.id.to_s, "name" => "", "siren" => "123"})
    refused.status.should eq(422)
    refused.html.should contain("Le nom est obligatoire.")
    refused.html.should contain("Le SIREN « 123 » n'est pas valide")

    response = browser.post("/cards/new", {"category_id" => customer.id.to_s, "name" => "Menuiserie Morel", "enabled" => "1",
                                           "email" => "contact@morel.example", "address.city" => "Nantes", "address.postcode" => "44000"})
    response.status.should eq(302)
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    page = browser.follow(response).html
    page.should contain("Menuiserie Morel")
    page.should contain("contact@morel.example")
    page.should contain("44000 Nantes")
    page.should contain("Comptabilité")

    list = browser.get("/cards").html
    list.should contain(%(<a class="pd-link" href="/cards/#{id}">))
    list.should contain("Nantes")
    browser.get("/cards?q=morel").html.should contain("Menuiserie Morel")
    browser.get("/cards?q=introuvable").html.should_not contain("Menuiserie Morel")

    browser.follow(browser.post("/cards/#{id}/enable")).html.should contain("Fiche Menuiserie Morel désactivée.")
    browser.get("/cards").html.should_not contain("Menuiserie Morel")
    browser.get("/cards?status=inactive").html.should contain("Menuiserie Morel")
    browser.follow(browser.post("/cards/#{id}/delete")).html.should contain("Fiche Menuiserie Morel supprimée.")
  end

  it "crée un article avec un prix saisi à la française et l'exporte" do
    browser = admin
    sale = PartiduoUi::Reference.category("SALE")
    rate = Partiduo::Api::Vat.rates(system).find! { |item| item.rate == BigDecimal.new(20) }
    form = browser.get("/cards/new?category=#{sale.id}").html
    form.should contain(%(name="sale_price"))
    form.should_not contain(%(name="siren"))

    refused = browser.post("/cards/new", {"category_id" => sale.id.to_s, "name" => "Pose", "sale_price" => "douze"})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez un nombre")

    response = browser.post("/cards/new", {"category_id" => sale.id.to_s, "name" => "Pose de parquet", "enabled" => "1",
                                           "unit_code" => "MTK", "sale_price" => "1 234,5", "vat_rate_id" => rate.id.to_s})
    response.status.should eq(302)
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    Partiduo::Api::Cards.card(system, id).sale_price.should eq(BigDecimal.new("1234.5"))

    items = browser.get("/cards/items").html
    items.should contain("<h1>Articles et services</h1>")
    items.should contain(%(<a href="/cards/items" aria-current="page">Articles et services</a>))
    items.should contain("1#{NNBSP}234,50")
    items.should contain("mètre carré")

    csv = browser.get("/cards/items?format=csv").content
    csv.should contain("Pose de parquet")
    csv.should contain(";1234,5000;")

    browser.post("/language", {"locale" => "en", "next" => "/"})
    browser.get("/cards/items").html.should contain("1#{NNBSP}234,50") # société française : conventions en-FR
  end

  it "suit les conventions belges en néerlandais" do
    browser = admin("be")
    sale = PartiduoUi::Reference.category("SALE")
    Partiduo::Api::Cards.create_card(system, Partiduo::Api::Cards::CardInput.new(category_id: sale.id, name: "Plaatsing",
      sale_price: BigDecimal.new("1234.5"))).value!
    browser.post("/language", {"locale" => "nl", "next" => "/"})
    page = browser.get("/cards/items").html
    page.should contain("1.234,50")
    page.should contain("<h1>Artikelen en diensten</h1>")
    csv = browser.get("/cards/items?format=csv").content
    csv.should contain(";1234,5000;")
    browser.get("/vat/rates").html.should contain("21%")
  end
end
