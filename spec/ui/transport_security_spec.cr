# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Relecture des lots P, 0 et 1 (D-UI-021, D-UI-022) : liens des courriels,
# cookies et HSTS derrière le proxy HTTPS, limitation par adresse IP.
describe "Transport sécurisé et points d'entrée anonymes" do
  it "bâtit les liens des courriels sur le domaine configuré, en https" do
    PartiduoUi::TokenMail.base_url("exemple.partiduo.fr").should eq("https://exemple.partiduo.fr")
    PartiduoUi::TokenMail.base_url("demo.partiduo.localhost").should match(%r{\Ahttp://demo\.partiduo\.localhost(:\d+)?\z})
  end

  it "ajoute Strict-Transport-Security aux seules réponses HTTPS" do
    middleware = PartiduoUi::StrictTransportSecurity.new
    plain = Marten::HTTP::Request.new(::HTTP::Request.new(method: "GET", resource: "/", headers: HTTP::Headers{"Host" => "localhost"}))
    middleware.call(plain, -> { Marten::HTTP::Response.new("ok") }).headers[:"Strict-Transport-Security"]?.should be_nil

    Marten.settings.use_x_forwarded_proto = true
    begin
      secure = Marten::HTTP::Request.new(::HTTP::Request.new(method: "GET", resource: "/",
        headers: HTTP::Headers{"Host" => "localhost", "X-Forwarded-Proto" => "https"}))
      header = middleware.call(secure, -> { Marten::HTTP::Response.new("ok") }).headers[:"Strict-Transport-Security"]?
      header.should eq("max-age=63072000; includeSubDomains")
      PartiduoUi::Current.secure_cookies?(secure).should be_true
    ensure
      Marten.settings.use_x_forwarded_proto = false
    end
  end

  it "limite par adresse les demandes anonymes de défi de passkey" do
    browser = PartiduoUi::Browser.new
    30.times { browser.post("/login/passkey/options").status.should eq(200) }
    refused = browser.post("/login/passkey/options")
    refused.status.should eq(429)
    refused.content.should contain("Trop de demandes")
  end

  it "n'envoie plus de lien au-delà de la limite, avec la même réponse" do
    PartiduoUi::Accounts.create
    Marten::Emailing::Backend::Development.delivered_emails.clear
    browser = PartiduoUi::Browser.new
    12.times do
      browser.post("/password/forgotten", {"email" => "personne@example.com"}).html.should contain("Vérifiez votre messagerie")
    end
    browser.post("/password/forgotten", {"email" => "alice@example.com"}).html.should contain("Vérifiez votre messagerie")
    Marten::Emailing::Backend::Development.delivered_emails.should be_empty
  end
end
