# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def activate_uitest
  Partiduo::Api::Modules.activate(PartiduoUi::Accounts.system, "UITEST").success?.should be_true
end

describe "Routes d'extension sous /ext/<CODE>/ (ADR-003 D3, ADR-005 D4)" do
  it "monte les routes de l'extension sous son code, nommées comme dans le manifeste" do
    Marten.routes.reverse("uitest:index").should eq("/ext/UITEST/")
    Marten.routes.reverse("uitest:edit").should eq("/ext/UITEST/edit")
    PartiduoUi::Extensions.match("/ext/UITEST/edit").try(&.[1]).should eq("uitest:edit")
    PartiduoUi::Extensions.match("/ext/UITEST/nope").should_not be_nil
    PartiduoUi::Extensions.match("/ext/UITEST/nope").try(&.[1]).should be_nil
    PartiduoUi::Extensions.match("/search").should be_nil
  end

  it "renvoie un visiteur non connecté vers la connexion" do
    activate_uitest
    response = PartiduoUi::Browser.new.get("/ext/UITEST/")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FUITEST%2F")
  end

  it "ignore une extension inactive (404), même pour un administrateur" do
    PartiduoUi::Accounts.create
    response = PartiduoUi::Accounts.signed_in.get("/ext/UITEST/")
    response.status.should eq(404)
    response.html.should contain("Page introuvable")
  end

  it "ouvre la page d'une extension active à un profil qui a la permission du menu" do
    activate_uitest
    PartiduoUi::Accounts.create
    response = PartiduoUi::Accounts.signed_in.get("/ext/UITEST/")
    response.status.should eq(200)
    response.content.should eq("page UITEST /ext/UITEST/")
  end

  it "refuse la page aux profils sans la permission, avant le handler" do
    activate_uitest
    profile = PartiduoUi::Accounts.profile("Sans extension", ["accounting.entry.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    response = PartiduoUi::Accounts.signed_in.get("/ext/UITEST/")
    response.status.should eq(403)
    response.html.should contain("Accès refusé")
    response.html.should_not contain("page UITEST")
  end

  it "applique la permission donnée au montage à sa route" do
    activate_uitest
    viewer = PartiduoUi::Accounts.profile("Lecteur", ["uitest.page.view"])
    editor = PartiduoUi::Accounts.profile("Rédacteur", ["uitest.page.view", "uitest.page.edit"])
    PartiduoUi::Accounts.create(email: "viewer@example.com", profile: nil, profile_id: viewer)
    PartiduoUi::Accounts.create(email: "editor@example.com", profile: nil, profile_id: editor)

    viewing = PartiduoUi::Accounts.signed_in("viewer@example.com")
    viewing.get("/ext/UITEST/").status.should eq(200)
    viewing.get("/ext/UITEST/edit").status.should eq(403)
    PartiduoUi::Accounts.signed_in("editor@example.com").get("/ext/UITEST/edit").status.should eq(200)
  end

  it "n'ouvre jamais une route que ni le montage ni le manifeste ne couvrent" do
    activate_uitest
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/ext/UITEST/hidden").status.should eq(403)
    # Permission citée au montage mais non déclarée par le manifeste de l'extension.
    browser.get("/ext/UITEST/undeclared").status.should eq(403)
  end

  it "contrôle aussi le chemin sans barre finale : jamais de handler atteint directement" do
    activate_uitest
    PartiduoUi::Accounts.create
    response = PartiduoUi::Accounts.signed_in.get("/ext/UITEST")
    response.status.should eq(403)
    response.content.should_not contain("page UITEST")
    PartiduoUi::Browser.new.get("/ext/UITEST").status.should eq(302) # anonyme : connexion
  end

  it "renvoie une session sous le niveau exigé vers l'élévation" do
    activate_uitest
    PartiduoUi::Accounts.create(email: "compta@example.com", role: "accountant", profile: "ACCOUNTANT")
    browser = PartiduoUi::Accounts.signed_in("compta@example.com")
    browser.get("/ext/UITEST/").headers["Location"].should eq("/account/security")
  end

  it "ne concerne pas un module officiel (pas de /ext/ACCOUNTING/)" do
    PartiduoUi::Accounts.create
    PartiduoUi::Accounts.signed_in.get("/ext/ACCOUNTING/").status.should eq(404)
  end
end
