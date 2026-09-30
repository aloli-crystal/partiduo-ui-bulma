# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# ADR-007 D3 — mode simplifié de la micro-entreprise : menu réduit,
# vocabulaire courant, tableau de bord (chiffre d'affaires, seuils,
# échéance URSSAF), saisie d'une recette ou d'un achat en quelques champs,
# facturation allégée (mention 293 B en franchise), URSSAF et 2042-C-PRO,
# mode complet réservé au comptable. Tout par `Partiduo::Api`.

private alias Micro = Partiduo::Api::Micro
private alias Books = PartiduoUi::Books

# Dossier micro-entreprise : Micro et Facturation actifs, Comptabilité
# inactive (configuration `micro,invoicing` d'ADR-007).
private def micro_books(accounting : Bool = false) : PartiduoUi::Browser
  browser = Books.admin
  unless accounting
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  end
  Partiduo::Api::Modules.activate(Books.system, "MICRO").success?.should be_true
  Micro.load_defaults(Books.system)
  browser
end

private def nature(code : String) : Micro::NatureView
  Micro.natures(Books.system).find! { |item| item.code == code }
end

private def receipt(day : String, amount : String, code : String = "SERVICE", party : String = "Atelier Morel") : Micro::LineView
  input = Micro::ReceiptInput.new(date: Books.date(day), nature_id: nature(code).id, amount: Books.d(amount), method: "transfer",
    party_name: party)
  Micro.record_receipt(Books.system, input).value!
end

private def purchase(day : String, amount : String) : Micro::LineView
  input = Micro::PurchaseInput.new(date: Books.date(day), nature_id: nature("SUPPLIES").id, amount: Books.d(amount), method: "card",
    party_name: "Papeterie Centrale")
  Micro.record_purchase(Books.system, input).value!
end

# Vocabulaire courant (ADR-007 D3) : jamais « débit » ni « crédit » à
# l'écran (attributs et scripts exclus).
private def plain_words(html : String) : String
  html.gsub(/<script.*?<\/script>/m, "").gsub(/<[^>]+>/, " ")
end

describe "Mode simplifié de la micro-entreprise (ADR-007 D3)" do
  it "n'existe pas quand le module est inactif : menu et tableau de bord complets, écrans 404" do
    browser = Books.admin
    page = browser.get("/").html
    page.should_not contain("pd-simple")
    page.should contain("Saisie")
    %w[/micro/receipts /micro/receipts/new /micro/purchases /micro/urssaf /micro/tax-return /micro/thresholds
      /micro/settings /micro/invoices/new].each do |path|
      browser.get(path).status.should eq(404), path
    end
  end

  it "présente le menu réduit et le tableau de bord centré sur le chiffre d'affaires, en langage courant" do
    browser = micro_books
    receipt("2026-03-10", "1200")
    purchase("2026-03-12", "80")
    response = browser.get("/")
    response.status.should eq(200)
    page = response.html
    page.should contain("pd-simple")
    menu = page.match!(/<nav class="pd-side menu".*?<\/nav>/m)[0]
    labels = menu.scan(/<a href="[^"]+"[^>]*><span>([^<]+)<\/span>/).map(&.[1])
    labels.should eq(["Tableau de bord", "Recettes", "Achats", "Factures", "URSSAF"])
    page.should contain("Chiffre d'affaires 2026")
    page.should contain("1\u202F200,00 €")
    page.should contain("Dépensé en 2026")
    page.should contain("80,00 €")
    page.should contain("Seuils 2026")
    page.should contain("Franchise de TVA")
    page.should contain("Nouvelle recette")
    page.should contain(%(href="/micro/invoices/new"))
    page.should_not contain("missing translation")
    plain_words(page).should_not match(/d[ée]bit|cr[ée]dit/i)
    # Paramètres de la micro-entreprise depuis le menu de l'utilisateur.
    page.should contain(%(href="/micro/settings"))
    # Le choix du mode n'est offert qu'au comptable.
    page.should_not contain(%(action="/mode"))
    browser.post("/mode", {"mode" => "full"}).status.should eq(403)
  end

  it "saisit une recette en quelques champs, pensée pour le téléphone" do
    browser = micro_books
    form = browser.get("/micro/receipts/new").html
    form.should contain(%(inputmode="decimal"))
    form.should contain(%(capture="environment"))
    form.should contain(%(enctype="multipart/form-data"))
    form.should contain("Plus de détails")
    form.should contain(%(value="#{Partiduo::Api::Core.today.to_s("%Y-%m-%d")}"))
    plain_words(form).should_not match(/d[ée]bit|cr[ée]dit/i)

    refused = browser.post("/micro/receipts/new", {"amount" => "", "date" => "2026-03-10", "nature_id" => nature("SALE").id.to_s,
                                                   "method" => "cash"})
    refused.status.should eq(422)
    refused.html.should contain("Ce champ est obligatoire.")
    future = browser.post("/micro/receipts/new", {"amount" => "10", "date" => (Partiduo::Api::Core.today + 2.days).to_s("%Y-%m-%d"),
                                                  "nature_id" => nature("SALE").id.to_s, "method" => "cash"})
    future.status.should eq(422)
    future.html.should contain("Date à venir")

    saved = browser.post("/micro/receipts/new", {"amount" => "120,50", "date" => "2026-03-10", "nature_id" => nature("SERVICE").id.to_s,
                                                 "method" => "card", "party_name" => "Atelier Morel", "label" => "Réparation"})
    saved.status.should eq(302)
    saved.headers["Location"].should eq("/micro/receipts")
    line = Micro.receipts(Books.system).first
    line.amount.should eq(Books.d("120.5"))
    line.method.should eq("card")
    line.party_name.should eq("Atelier Morel")
    list = browser.follow(saved).html
    list.should contain("Recette #{line.number} enregistrée : 120,50 € encaissés.")
    list.should contain("Total encaissé")
    list.should contain("Atelier Morel")
    # « Enregistrer et en saisir une autre » ramène au formulaire.
    again = browser.post("/micro/receipts/new", {"amount" => "5", "date" => "2026-03-11", "nature_id" => nature("SALE").id.to_s,
                                                 "method" => "cash", "again" => "1"})
    again.headers["Location"].should eq("/micro/receipts/new")
  end

  it "saisit un achat, le contre-passe une fois le trimestre déclaré et édite les registres" do
    browser = micro_books
    saved = browser.post("/micro/purchases/new", {"amount" => "42", "date" => "2026-03-12", "nature_id" => nature("SUPPLIES").id.to_s,
                                                  "method" => "card", "party_name" => "Papeterie Centrale"})
    saved.status.should eq(302)
    line = Micro.purchases(Books.system).first
    browser.follow(saved).html.should contain("Achat #{line.number} enregistré : 42,00 € dépensés.")
    show = browser.get("/micro/purchases/#{line.id}").html
    # Trimestre pas encore déclaré : modifier ou supprimer (D-MIC2-001).
    show.should contain("Modifier")
    show.should contain("Supprimer")
    show.should_not contain("Contre-passer")
    show.should contain("Papeterie Centrale")
    Micro.mark_declared(Books.system, Micro::DeclarationInput.new(Books.date("2026-01-01"), Books.date("2026-04-10"))).value!
    show = browser.get("/micro/purchases/#{line.id}").html
    show.should contain("Contre-passer")
    show.should contain("Période déclarée à l'URSSAF le 10/04/2026")
    show.should_not contain(%(href="/micro/purchases/#{line.id}/edit"))

    cancelled = browser.post("/micro/purchases/#{line.id}/reverse")
    cancelled.headers["Location"].should eq("/micro/purchases/#{line.id}")
    reversed_id = Micro.purchase(Books.system, line.id).reversed_by_id || raise "achat non annulé"
    reversal = Micro.purchase(Books.system, reversed_id)
    reversal.amount.should eq(Books.d("-42"))
    reversal.date.should eq(Partiduo::Api::Core.today)
    page = browser.follow(cancelled).html
    page.should contain("annulée par #{reversal.number}")
    page.should_not contain("Contre-passer")
    browser.post("/micro/purchases/#{line.id}/reverse").status.should eq(302)
    Micro.purchases(Books.system).size.should eq(2)

    csv = browser.get("/micro/purchases?year=2026&format=csv")
    csv.status.should eq(200)
    csv.content_type.should contain("text/csv")
    csv.headers["Content-Disposition"].should contain("attachment")
    pdf = browser.get("/micro/receipts?format=pdf")
    pdf.content_type.should eq("application/pdf")
    pdf.content.should start_with("%PDF-")
  end

  it "montre les montants à reporter à l'URSSAF et note la déclaration faite" do
    browser = micro_books
    Micro.update_settings(Books.system, Micro::SettingsInput.new(periodicity: "quarterly",
      activity_started_on: Books.date("2026-01-01"), default_nature_id: nature("SALE").id)).success?.should be_true
    receipt("2026-02-10", "1000.40", "SALE")
    receipt("2026-03-10", "500", "SERVICE")
    page = browser.get("/micro/urssaf?year=2026").html
    page.should contain("Prochaine déclaration")
    page.should contain("À reporter")
    page.should contain("1\u202F000 €")
    page.should contain("500 €")
    page.should contain("J'ai déclaré sur le site de l'URSSAF")
    page.should contain("Échéances de l'année")
    page.should_not contain("missing translation")

    declared = browser.post("/micro/urssaf/declare", {"starts_on" => "2026-01-01", "reference" => "DEC-2026-T1"})
    declared.headers["Location"].should eq("/micro/urssaf?year=2026")
    Micro.declarations(Books.system, 2026).first.status.should eq("declared")
    browser.follow(declared).html.should contain("Déclaration de la période")
    browser.post("/micro/urssaf/declare", {"starts_on" => "2026-01-01"})
    browser.get("/micro/urssaf?year=2026").html.should contain("Période déjà déclarée")

    tax = browser.get("/micro/tax-return?year=2026").html
    tax.should contain("Case 5KO")
    tax.should contain("1\u202F000 €")
    thresholds = browser.get("/micro/thresholds?year=2026").html
    thresholds.should contain("Franchise en base de TVA")
    thresholds.should contain("Sous le seuil")
  end

  it "modifie les paramètres de la micro-entreprise" do
    browser = micro_books
    browser.get("/micro/settings").status.should eq(200)
    refused = browser.post("/micro/settings", {"periodicity" => "monthly", "activity_started_on" => "demain"})
    refused.status.should eq(422)
    saved = browser.post("/micro/settings", {"periodicity" => "monthly", "flat_tax" => "1", "activity_started_on" => "2026-02-01",
                                             "default_nature_id" => nature("SERVICE").id.to_s})
    saved.status.should eq(302)
    settings = Micro.settings(Books.system)
    settings.periodicity.should eq("monthly")
    settings.flat_tax.should be_true
    settings.activity_started_on.should eq(Books.date("2026-02-01"))
  end

  it "facture en quelques champs, mention 293 B d'office en franchise en base" do
    browser = micro_books
    form = browser.get("/micro/invoices/new").html
    form.should contain("TVA non applicable, art. 293 B du CGI")
    form.should_not contain(%(name="vat_rate_id"))
    browser.get("/invoicing/documents").html.should contain(%(href="/micro/invoices/new"))

    refused = browser.post("/micro/invoices/new", {"line-0-description" => "Réparation", "line-0-price" => "80"})
    refused.status.should eq(422)
    refused.html.should contain("Choisissez un client ou indiquez son nom.")
    # Saisie illisible : le nouveau client n'est pas créé.
    unreadable = browser.post("/micro/invoices/new", {"customer_name" => "Client fantôme", "line-0-description" => "Réparation",
                                                      "line-0-price" => "abc"})
    unreadable.status.should eq(422)
    unreadable.html.should contain(%(aria-describedby="pd-ml0-errors"))
    Partiduo::Api::Cards.cards(Books.system, Partiduo::Api::Cards::CardQuery.new(search: "fantôme")).should be_empty

    created = browser.post("/micro/invoices/new", {"customer_name" => "Atelier Morel", "line-0-description" => "Réparation",
                                                   "line-0-quantity" => "2", "line-0-price" => "40,50", "due_date" => "2026-12-31"})
    created.status.should eq(302)
    document = Partiduo::Api::Invoicing.documents(Books.system).first
    created.headers["Location"].should eq("/invoicing/documents/#{document.id}")
    document.customer.name.should eq("Atelier Morel")
    document.lines.size.should eq(1)
    franchise = Partiduo::Api::Vat.rates(Books.system).find! { |rate| rate.exemption_code == "VATEX-FR-FRANCHISE" }
    document.lines.first.vat_rate_id.should eq(franchise.id)
    document.totals.total_gross.should eq(Books.d("81"))

    # Même commande du module Facturation : client existant choisi.
    browser.post("/micro/invoices/new", {"customer_id" => document.customer_card_id.to_s, "line-0-description" => "Conseil",
                                         "line-0-price" => "100"}).status.should eq(302)
    Partiduo::Api::Invoicing.documents(Books.system).size.should eq(2)
  end

  it "reste disponible avec la Comptabilité active (configuration micro, facturation, comptabilité)" do
    browser = micro_books(accounting: true)
    receipt("2026-03-10", "300")
    page = browser.get("/").html
    page.should contain("pd-simple")
    page.should contain("300,00 €")
    browser.get("/micro/receipts").status.should eq(200)
  end

  it "est traduit en anglais et en néerlandais" do
    browser = micro_books
    line = receipt("2026-03-10", "100")
    {"en" => "Turnover 2026", "nl" => "Omzet 2026"}.each do |locale, title|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      ["/", "/micro/receipts", "/micro/receipts/new", "/micro/receipts/#{line.id}", "/micro/purchases", "/micro/urssaf",
       "/micro/tax-return", "/micro/thresholds", "/micro/settings", "/micro/invoices/new"].each do |path|
        response = browser.get(path)
        response.status.should eq(200), "#{locale} #{path} : #{response.status}"
        response.html.should_not contain("missing translation"), "#{locale} #{path}"
        response.html.should contain(%(<html lang="#{locale}">))
      end
      browser.get("/").html.should contain(title)
    end
  end

  it "laisse le mode complet au comptable, qui choisit son mode et le retrouve d'une session à l'autre (D-UI-077)" do
    PartiduoUi::SimpleMode.interfaces("MICRO", "member", true).should eq(["simple"])
    PartiduoUi::SimpleMode.interfaces("MICRO", "accountant", false).should eq(["simple", "full"])
    PartiduoUi::SimpleMode.choose("full", ["simple"]).should eq("simple")
    PartiduoUi::SimpleMode.choose("simple", ["simple", "full"]).should eq("simple")

    micro_books
    PartiduoUi::Accounts.create(email: "compta@example.com", role: "accountant", profile: "ACCOUNTANT")
    browser = PartiduoUi::Accounts.signed_in("compta@example.com")
    authenticator = PartiduoUi::FakeAuthenticator.new
    options = browser.post("/account/passkeys/options").html
    JSON.parse(browser.post("/account/passkeys", authenticator.register(options)).html)["ok"].as_bool.should be_true
    sign_in = -> do
      session = PartiduoUi::Browser.new
      login = session.post("/login/passkey/options").html
      JSON.parse(session.post("/login/passkey", authenticator.assert(login)).html)["ok"].as_bool.should be_true
      session
    end
    accountant = sign_in.call

    full = accountant.get("/").html
    full.should_not contain("pd-simple")
    full.should contain("Passer au mode simplifié")
    accountant.post("/mode", {"mode" => "simple"}).headers["Location"].should eq("/")
    simple = accountant.get("/").html
    simple.should contain("pd-simple")
    simple.should contain("Passer au mode complet")
    # Préférence enregistrée avec le compte, sans cookie : retrouvée à la connexion suivante.
    accountant.jar.has_key?("partiduo_mode").should be_false
    sign_in.call.get("/").html.should contain("pd-simple")
    preferences = accountant.get("/account/preferences").html
    preferences.should contain(%(<option value="simple" selected>Mode simplifié</option>))
    preferences.should contain(%(<option value="full">Mode complet</option>))
    accountant.post("/account/preferences", {"interface" => "full"}).headers["Location"].should eq("/account/preferences")
    accountant.get("/").html.should_not contain("pd-simple")
    accountant.post("/mode", {"mode" => "full"}).status.should eq(403) # déjà en mode complet
  end

  it "garde le mode simplifié aux utilisateurs de la société, quelle que soit leur préférence" do
    browser = micro_books
    page = browser.get("/account/preferences").html
    page.should_not contain(%(name="interface"))
    page.should contain("Interface appliquée : Mode simplifié.")
    page.should contain("aux utilisateurs de la société")
    browser.post("/account/preferences", {"interface" => "full"}).status.should eq(422)
    browser.get("/").html.should contain("pd-simple")
  end
end
