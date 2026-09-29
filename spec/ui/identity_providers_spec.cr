# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Fournisseurs d'identité et connexion fédérée dans l'interface (ADR-002 D3,
# BLOCAGES B-CRIT-002, DECISIONS D-R5-009, D-R5-010).

private alias Books = PartiduoUi::Books
private alias Auth = Partiduo::Api::Auth

private ISSUER = "https://login.cabinet.test"

# Méthode « fournisseur d'identité » admise par la politique du dossier.
private def allow_federated : Nil
  settings = Partiduo::Api::Core.settings(Books.system)
  input = settings.to_input.copy_with(auth_methods: (settings.auth_methods + ["federated"]).uniq)
  Partiduo::Api::Core.update_settings(Books.system, input).value!
end

private def oidc_values(extra = {} of String => String) : Hash(String, String)
  {"kind" => "oidc", "code" => "cabinet", "name" => "Cabinet Durand", "level" => "2", "active" => "1",
   "settings.issuer" => ISSUER, "settings.authorization_endpoint" => "#{ISSUER}/authorize",
   "settings.token_endpoint" => "#{ISSUER}/token", "settings.jwks_uri" => "#{ISSUER}/keys",
   "settings.client_id" => "partiduo", "settings.client_secret" => "s3cret",
   "settings.redirect_uri" => "https://demo.partiduo.localhost/login/federated/cabinet/callback"}.merge(extra)
end

describe "Fournisseurs d'identité (interface)" do
  it "crée un fournisseur OIDC, ne réaffiche jamais le secret et le garde quand il est laissé vide" do
    browser = Books.admin
    browser.get("/settings/users").html.should contain(%(href="/settings/identity-providers"))
    list = browser.get("/settings/identity-providers").html
    list.should contain("Aucun fournisseur d'identité.")
    list.should contain("Nouveau fournisseur OpenID Connect")
    list.should contain("Nouveau fournisseur SAML 2.0")
    form = browser.get("/settings/identity-providers/new?kind=oidc").html
    form.should contain(%(name="settings.client_secret"))
    form.should contain(%(type="password"))
    form.should contain("Adresse de retour à déclarer chez le fournisseur")

    refused = browser.post("/settings/identity-providers/new", oidc_values({"settings.token_endpoint" => "http://x.example/t"}))
    refused.status.should eq(422)
    refused.html.should contain("Adresse HTTPS attendue")
    refused.html.should_not contain("s3cret")

    created = browser.post("/settings/identity-providers/new", oidc_values)
    created.status.should eq(302)
    edit = browser.follow(created).html
    edit.should contain("Cabinet Durand")
    edit.should_not contain("s3cret")
    edit.should contain("Enregistré ; laissez vide pour le garder")
    browser.post("/settings/identity-providers/cabinet", oidc_values({"settings.client_secret" => "", "level" => "3"}))
      .status.should eq(302)
    detail = Auth.identity_provider(Books.system, "cabinet")
    {detail.level, detail.secrets_set}.should eq({3, ["client_secret"]})
    browser.get("/settings/identity-providers").html.should contain("3 — clé d'accès (passkey)")
    browser.post("/settings/identity-providers/new", oidc_values).html.should contain("Ce code est déjà utilisé.")
  end

  it "rattache une identité à un utilisateur, puis la détache" do
    browser = Books.admin
    browser.post("/settings/identity-providers/new", oidc_values).status.should eq(302)
    user = Auth.users(Books.system).first
    browser.get("/settings/users/#{user.id}").html.should contain(%(href="/settings/users/#{user.id}/identities"))
    browser.post("/settings/users/#{user.id}/identities", {"provider" => "cabinet", "subject" => ""}).status.should eq(422)
    browser.post("/settings/users/#{user.id}/identities", {"provider" => "cabinet", "subject" => "sub-42"}).status.should eq(302)
    page = browser.get("/settings/users/#{user.id}/identities").html
    page.should contain("sub-42")
    identity = Auth.federated_identities(Books.system, user.id).first
    browser.post("/settings/users/#{user.id}/identities/#{identity.id}/unlink").status.should eq(302)
    Auth.federated_identities(Books.system, user.id).should be_empty
  end

  it "part vers le fournisseur depuis l'écran de connexion et traite son retour (refus rendu à l'écran)" do
    admin = Books.admin
    admin.post("/settings/identity-providers/new", oidc_values).status.should eq(302)
    allow_federated

    browser = PartiduoUi::Browser.new
    login = browser.get("/login").html
    login.should contain("Continuer avec Cabinet Durand")
    login.should contain(%(href="/login/federated/cabinet"))
    start = browser.get("/login/federated/cabinet?next=/cards")
    start.status.should eq(302)
    location = start.headers["Location"]
    location.should start_with("#{ISSUER}/authorize?response_type=code")
    query = URI.parse(location).query_params
    {query["client_id"], query["code_challenge_method"]}.should eq({"partiduo", "S256"})
    browser.cookie(PartiduoUi::Current::FEDERATED_COOKIE).should_not be_nil

    # Refus du fournisseur : message traduit sur l'écran de connexion, cookie
    # de requête consommé. (La connexion réussie est vérifiée par le cœur,
    # spec/auth/oidc_spec.cr : l'interface ne remplace pas son transport.)
    refused = browser.get("/login/federated/cabinet/callback?error=access_denied&state=#{URI.encode_www_form(query["state"])}")
    refused.status.should eq(302)
    refused.headers["Location"].should eq("/login")
    browser.cookie(PartiduoUi::Current::FEDERATED_COOKIE).should be_nil
    browser.follow(refused).html.should contain("Le fournisseur d'identité a refusé la connexion.")
    browser.cookie(PartiduoUi::Current::COOKIE).should be_nil

    # Retour sans départ (cookie absent) : requête expirée.
    PartiduoUi::Browser.new.get("/login/federated/cabinet/callback?code=x&state=y").headers["Location"].should eq("/login")
    browser.get("/login/federated/inconnu").status.should eq(404)
  end

  it "accepte la réponse SAML par un POST sans jeton CSRF (contrôlée par le cœur)" do
    PartiduoUi::Books.admin
    allow_federated
    browser = PartiduoUi::Browser.new
    # Fournisseur inconnu : refus du cœur (404), jamais un refus CSRF (403).
    browser.post("/login/federated/idp/acs", {"SAMLResponse" => "PHNhbWw+", "RelayState" => "idp"}).status.should eq(404)
  end

  it "masque la connexion fédérée quand la politique du dossier ne l'admet pas" do
    admin = Books.admin
    admin.post("/settings/identity-providers/new", oidc_values).status.should eq(302)
    PartiduoUi::Browser.new.get("/login").html.should_not contain("Continuer avec")
    allow_federated
    PartiduoUi::Browser.new.get("/login").html.should contain("Continuer avec Cabinet Durand")
  end
end
