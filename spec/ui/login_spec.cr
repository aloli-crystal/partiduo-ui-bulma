# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def login(browser, password = PartiduoUi::Accounts::PASSWORD, email = "alice@example.com")
  browser.post("/login", {"email" => email, "password" => password})
end

describe "Connexion (ADR-002)" do
  it "propose la clé d'accès avant le mot de passe" do
    body = PartiduoUi::Browser.new.get("/login").html
    passkey = body.index!(%(data-passkey="login"))
    password = body.index!(%(name="password"))
    passkey.should be < password
    body.should contain(%(src="/assets/ui/js/passkey.js"))
    body.should contain(%(autocomplete="username webauthn"))
    body.should contain(%(autocomplete="current-password"))
    body.should contain(%(<label class="label" for="pd-email">Adresse électronique</label>))
  end

  it "ouvre la session par mot de passe, dans un cookie HttpOnly, puis propose la clé d'accès" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Browser.new
    response = login(browser)
    response.status.should eq(302)
    response.headers["Location"].should eq("/account/passkey-prompt")
    browser.cookie(PartiduoUi::Current::COOKIE).should_not be_nil

    prompt = browser.get("/account/passkey-prompt").html
    prompt.should contain("Passez à la clé d'accès")
    prompt.should contain(%(data-passkey="register"))

    later = browser.post("/account/passkey-prompt", {"next" => "/search"})
    later.headers["Location"].should eq("/search")
    login(PartiduoUi::Browser.new).headers["Location"].should eq("/")
  end

  it "revient à la page demandée après la connexion" do
    PartiduoUi::Accounts.create
    Partiduo::Api::Auth.dismiss_passkey_prompt(Partiduo::Api::Auth.actor(PartiduoUi::Accounts.token))
    response = PartiduoUi::Browser.new.post("/login", {"email" => "alice@example.com",
                                                       "password" => PartiduoUi::Accounts::PASSWORD, "next" => "/search?q=1"})
    response.headers["Location"].should eq("/search?q=1")
  end

  it "refuse un mauvais mot de passe sans dire si l'adresse existe" do
    PartiduoUi::Accounts.create
    known = login(PartiduoUi::Browser.new, "Wrongpassword42abc")
    unknown = login(PartiduoUi::Browser.new, "Wrongpassword42abc", "nobody@example.com")
    known.status.should eq(422)
    known.html.should contain("Adresse ou mot de passe incorrect.")
    known.html.should contain(%(role="alert"))
    unknown.html.should contain("Adresse ou mot de passe incorrect.")
  end

  it "affiche la temporisation puis le blocage, avec le lien de déblocage (CNIL 2022-100)" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Browser.new
    3.times { login(browser, "Wrongpassword42abc") }
    throttled = login(browser, "Wrongpassword42abc")
    throttled.status.should eq(422)
    throttled.html.should match(/Trop de tentatives : réessayez dans \d+ secondes?\./)
    throttled.html.should contain("/assets/ui/icons/sprite.svg#clock")
  end

  it "affiche le blocage avec le lien de déblocage" do
    result = Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("auth.errors.login.locked"))
    throttling = PartiduoUi::LoginFlow.throttling(result)
    throttling["locked"].should be_true
    context = Marten::Template::Context.from({
      "errors"     => {"base" => result.errors.map(&.message)},
      "throttling" => throttling,
      "email"      => "",
      "next"       => "",
      "company"    => "demo",
    })
    body = HTML.unescape(Marten.templates.get_template("ui/auth/login.html").render(context))
    body.should contain("Compte bloqué après trop d'échecs.")
    body.should contain(%(href="/unlock"))
    body.should contain("/assets/ui/icons/sprite.svg#lock")
  end

  it "demande le code de l'application d'authentification, puis ouvre la session" do
    PartiduoUi::Accounts.create
    secret = PartiduoUi::Accounts.enable_totp
    browser = PartiduoUi::Browser.new
    step = login(browser)
    step.headers["Location"].should start_with("/login/second-factor?factors=totp%2Crecovery_code")
    browser.cookie(PartiduoUi::Current::COOKIE).should be_nil

    page = browser.follow(step).html
    page.should contain("Code de l'application d'authentification")
    page.should contain(%(autocomplete="one-time-code"))
    page.should contain("Utiliser plutôt un code de récupération")

    wrong = browser.post("/login/second-factor", {"kind" => "totp", "code" => "000000", "factors" => "totp,recovery_code"})
    wrong.status.should eq(422)
    wrong.html.should contain("Code incorrect.")

    done = browser.post("/login/second-factor", {"kind" => "totp", "code" => PartiduoUi::Accounts.totp_code(secret)})
    done.status.should eq(302)
    browser.cookie(PartiduoUi::Current::COOKIE).should_not be_nil
    browser.cookie(PartiduoUi::Current::PENDING_COOKIE).should be_nil
  end

  it "accepte un code de récupération à la place du TOTP" do
    PartiduoUi::Accounts.create
    token = PartiduoUi::Accounts.token
    actor = Partiduo::Api::Auth.actor(token)
    enrollment = Partiduo::Api::Auth.begin_totp_enrollment(actor)
    codes = Partiduo::Api::Auth.confirm_totp_enrollment(actor,
      PartiduoUi::Accounts.totp_code(enrollment.secret_base32, Time.utc - 30.seconds)).value!.codes

    browser = PartiduoUi::Browser.new
    login(browser)
    browser.post("/login/second-factor", {"kind" => "recovery_code", "code" => codes.first}).status.should eq(302)
    browser.cookie(PartiduoUi::Current::COOKIE).should_not be_nil
  end

  it "se connecte par clé d'accès, sans identifiant (JSON de passkey.js)" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    authenticator = PartiduoUi::FakeAuthenticator.new
    options = browser.post("/account/passkeys/options").html
    registered = JSON.parse(browser.post("/account/passkeys", authenticator.register(options)).html)
    registered["ok"].as_bool.should be_true
    registered["html"].as_s.should contain("Codes de récupération")

    fresh = PartiduoUi::Browser.new
    options = fresh.post("/login/passkey/options").html
    JSON.parse(options)["publicKey"]["allowCredentials"].as_a.should be_empty
    outcome = JSON.parse(fresh.post("/login/passkey", authenticator.assert(options).merge({"next" => "/search"})).html)
    outcome["ok"].as_bool.should be_true
    outcome["redirect"].as_s.should eq("/search")
    fresh.cookie(PartiduoUi::Current::COOKIE).should_not be_nil
    fresh.get("/").status.should eq(200)
  end

  it "refuse une assertion de passkey invalide" do
    PartiduoUi::Accounts.create
    fresh = PartiduoUi::Browser.new
    options = fresh.post("/login/passkey/options").html
    response = fresh.post("/login/passkey", PartiduoUi::FakeAuthenticator.new.assert(options))
    response.status.should eq(422)
    JSON.parse(response.html)["ok"].as_bool.should be_false
  end

  it "ferme la session à la déconnexion" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    token = browser.cookie(PartiduoUi::Current::COOKIE)
    browser.post("/logout").headers["Location"].should eq("/login")
    browser.cookie(PartiduoUi::Current::COOKIE).should be_nil
    Partiduo::Api::Auth.session(token).should be_nil
    browser.get("/").status.should eq(302)
  end

  it "envoie un lien de remise à zéro, avec la même réponse pour une adresse inconnue" do
    PartiduoUi::Accounts.create
    Marten::Emailing::Backend::Development.delivered_emails.clear
    known = PartiduoUi::Browser.new.post("/password/forgotten", {"email" => "Alice@Example.com"}).html
    unknown = PartiduoUi::Browser.new.post("/password/forgotten", {"email" => "nobody@example.com"}).html
    strip = ->(html : String) { html.gsub(/[A-Za-z0-9_-]{60,}/, "") }
    strip.call(known).should eq(strip.call(unknown))
    emails = Marten::Emailing::Backend::Development.delivered_emails
    emails.size.should eq(1)
    emails.first.to.map(&.address).should eq(["alice@example.com"]) # adresse enregistrée, pas celle saisie
    # Lien bâti sur le domaine configuré, pas sur l'en-tête Host de la requête.
    # (instance sans société : domaine des instances, en .localhost en test).
    link = emails.first.text_body.to_s.match!(/http:\/\/[a-z0-9.-]+\.localhost(?::\d+)?\/password\/reset\/(\S+)/)
    token = link[1]

    browser = PartiduoUi::Browser.new
    browser.get("/password/reset/#{token}").html.should contain("au moins 14 caractères")
    mismatch = browser.post("/password/reset/#{token}", {"new_password" => "Anothergood42pass", "confirmation" => "x"})
    mismatch.status.should eq(422)
    done = browser.post("/password/reset/#{token}", {"new_password" => "Anothergood42pass", "confirmation" => "Anothergood42pass"})
    done.headers["Location"].should eq("/login")
    login(PartiduoUi::Browser.new, "Anothergood42pass").status.should eq(302)
  end

  it "propose le lien de déblocage, avec la même réponse pour tout compte" do
    PartiduoUi::Accounts.create
    form = PartiduoUi::Browser.new.get("/unlock?email=alice%40example.com").html
    form.should contain("Débloquer mon compte")
    form.should contain(%(value="alice@example.com"))
    sent = PartiduoUi::Browser.new.post("/unlock", {"email" => "alice@example.com"}).html
    sent.should contain("Vérifiez votre messagerie")
  end

  it "refuse un lien de déblocage inconnu" do
    response = PartiduoUi::Browser.new.post("/unlock/inconnu")
    response.status.should eq(422)
    response.html.should contain("Ce lien n'est plus valable.")
  end
end
