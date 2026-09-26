# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Coquille de l'écran (maquette, ADR-005 D5)" do
  it "renvoie un visiteur non connecté vers la connexion, avec la page demandée" do
    response = PartiduoUi::Browser.new.get("/search?q=512")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fsearch%3Fq%3D512")
  end

  it "affiche la barre supérieure, le menu latéral et la zone de contenu" do
    PartiduoUi::Accounts.create
    body = PartiduoUi::Accounts.signed_in.get("/").html

    body.should contain(%(<html lang="fr">))
    body.should contain(%(<a class="pd-skip" href="#pd-main">Aller au contenu</a>))
    # Barre supérieure : dossier, exercice et période, recherche, langue, utilisateur.
    body.should contain(%(class="pd-dossier"))
    body.should contain("Exercice")
    body.should contain("Période")
    body.should contain(%(role="search"))
    body.should contain(%(<label class="is-sr-only" for="pd-search">Recherche</label>))
    body.should contain(%(<select id="pd-lang" name="locale"))
    body.should contain(%(<span class="pd-avatar" aria-hidden="true">AM</span>))
    body.should contain("Alice Martin · Utilisateur de la société")
    body.should contain("Se déconnecter")
    # Menu latéral et contenu.
    body.should contain(%(<nav class="pd-side menu" id="pd-side" aria-label="Navigation principale">))
    body.should contain(%(<a href="/" class="is-active" aria-current="page"><span>Tableau de bord</span>))
    body.should contain(%(<nav class="pd-crumb" aria-label="Fil d'Ariane">))
    body.should contain("<h1>Tableau de bord</h1>")
    body.should contain(%(<main class="pd-main" id="pd-main" tabindex="-1">))
  end

  it "n'affiche que les modules actifs, puis les extensions (ADR-006)" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in

    body = browser.get("/").html
    body.should contain(">Facturation</p>")
    body.should contain(">Saisie</p>")
    body.should contain("Achats")
    body.should_not contain("Page de test")

    Partiduo::Api::Modules.deactivate(PartiduoUi::Accounts.system, "INVOICING").success?.should be_true
    Partiduo::Api::Modules.activate(PartiduoUi::Accounts.system, "UITEST").success?.should be_true
    body = browser.get("/").html
    body.should_not contain(">Facturation</p>")
    body.should contain(">Saisie</p>")
    extensions = body.index!(">Extensions</p>")
    body.index!("Page de test").should be > extensions
    body.index!(">Saisie</p>").should be < extensions
    body.should contain(%(<span class="pd-ext">UITEST</span>))
  end

  it "masque les entrées que le profil ne permet pas" do
    profile = PartiduoUi::Accounts.profile("Lecteur", ["accounting.entry.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    body = PartiduoUi::Accounts.signed_in.get("/").html
    body.should contain(">Consultation</p>")
    body.should_not contain(">Saisie</p>")
    body.should_not contain(">Facturation</p>")
  end

  it "montre désactivées les entrées dont l'écran n'est pas encore livré" do
    PartiduoUi::Accounts.create
    body = PartiduoUi::Accounts.signed_in.get("/").html
    body.should contain(%(<span class="pd-menu-off" aria-disabled="true"><span>Achats<span class="is-sr-only"> (bientôt disponible)</span>))
  end

  it "traduit les libellés d'écran en fr, en et nl, et garde le choix de langue" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    {"en" => "Dashboard", "nl" => "Dashboard", "fr" => "Tableau de bord"}.each do |locale, title|
      response = browser.post("/language", {"locale" => locale, "next" => "/"})
      response.headers["Location"].should eq("/")
      body = browser.get("/").html
      body.should contain(%(<html lang="#{locale}">))
      body.should contain("<h1>#{title}</h1>")
      body.should_not contain("translation missing")
    end
    browser.post("/language", {"locale" => "nl", "next" => "/"})
    browser.get("/").html.should contain("Hoofdnavigatie")
  end

  it "refuse un retour vers un autre site" do
    response = PartiduoUi::Browser.new.post("/language", {"locale" => "en", "next" => "//evil.example/"})
    response.headers["Location"].should eq("/login")
  end

  it "charge les feuilles de style et scripts de la coquille" do
    PartiduoUi::Accounts.create
    body = PartiduoUi::Accounts.signed_in.get("/").html
    body.should contain(%(href="/assets/ui/css/theme.css"))
    body.should contain(%(src="/assets/ui/js/htmx.min.js"))
    body.should contain(%(src="/assets/ui/js/shell.js"))
    body.should contain(%(<meta name="csrf-token"))
    body.should contain("/assets/ui/icons/sprite.svg#menu")
  end

  it "garde la démonstration Opal sur la page « À propos »" do
    PartiduoUi::Accounts.create
    body = PartiduoUi::Accounts.signed_in.get("/about").html
    body.should contain(%(src="/assets/ui/js/opal/demo.js"))
    body.should contain("data-opal-counter")
    body.should contain(Partiduo::API_VERSION)
  end

  it "affiche la recherche globale" do
    PartiduoUi::Accounts.create
    body = PartiduoUi::Accounts.signed_in.get("/search?q=411").html
    body.should contain("Recherche : « 411 »")
  end
end
