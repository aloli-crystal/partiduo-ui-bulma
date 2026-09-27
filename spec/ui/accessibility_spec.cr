# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Contrôles automatisables de WCAG 2.2 AA (ADR-005 D5) sur les pages rendues :
# langue, titre unique, champs étiquetés, boutons nommés, icônes décoratives
# masquées, lien d'évitement, aucun ordre de tabulation forcé. Le contraste
# et le focus visible relèvent de theme.css et app.css (spec plus bas).
private def check_accessibility(html : String, path : String) : Nil
  html.should match(/<html lang="(fr|en|nl)">/)
  html.should contain(%(class="pd-skip" href="#pd-main"))
  html.should contain(%(id="pd-main"))
  html.scan(/<h1[\s>]/).size.should eq(1), "#{path} : un seul titre de niveau 1"
  html.should_not match(/tabindex="[1-9]/)

  labels = html.scan(/<label[^>]*\bfor="([^"]+)"/).map(&.[1]).to_set
  html.scan(/<(input|select|textarea)\b([^>]*)>/) do |match|
    attributes = match[2]
    next if attributes.matches?(/type="(hidden|submit|button)"/)
    id = attributes.match(/\bid="([^"]+)"/).try(&.[1])
    labelled = attributes.includes?("aria-label=") || attributes.includes?("aria-labelledby=") || (id && labels.includes?(id))
    labelled.should be_true, "#{path} : champ sans étiquette : <#{match[1]}#{attributes}>"
  end

  html.scan(/<button\b([^>]*)>(.*?)<\/button>/m) do |match|
    text = match[2].gsub(/<svg.*?<\/svg>/m, "").gsub(/<[^>]+>/, "").strip
    (text.presence || match[1].includes?("aria-label=")).should be_truthy, "#{path} : bouton sans nom : #{match[0][0, 120]}"
  end

  html.scan(/<svg\b([^>]*)>/) do |match|
    decorative = match[1].includes?(%(aria-hidden="true"))
    described = match[1].includes?(%(role="img")) && match[1].includes?("aria-label=")
    (decorative || described).should be_true, "#{path} : SVG ni décoratif ni décrit"
  end
end

describe "Accessibilité (WCAG 2.2 AA)" do
  it "respecte les règles automatisables sur les écrans d'authentification" do
    %w[/login /password/forgotten /unlock].each do |path|
      check_accessibility(PartiduoUi::Browser.new.get(path).html, path)
    end
  end

  it "respecte les règles automatisables sur les écrans de l'application" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    %w[/ /account/security /account/totp /account/passkey-prompt /search?q=x /about].each do |path|
      response = browser.get(path)
      response.status.should eq(200)
      check_accessibility(response.html, path)
    end
  end

  it "respecte les règles automatisables sur les écrans du référentiel" do
    PartiduoUi::Reference.provision
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    year = PartiduoUi::Reference.fiscal_year(2026)
    customer = PartiduoUi::Reference.category("CUSTOMER")
    card = Partiduo::Api::Cards.create_card(Partiduo::Api::Actor.system,
      Partiduo::Api::Cards::CardInput.new(category_id: customer.id, name: "Morel")).value!
    account = Partiduo::Api::Accounting.account(Partiduo::Api::Actor.system, "400")
    ledger = Partiduo::Api::Accounting.ledgers(Partiduo::Api::Actor.system).first
    rate = Partiduo::Api::Vat.rates(Partiduo::Api::Actor.system).first
    paths = ["/fiscal-years", "/fiscal-years/#{year.id}", "/accounting/chart", "/accounting/chart/new",
             "/accounting/chart/#{account.id}", "/accounting/chart/#{account.id}/edit", "/accounting/ledgers",
             "/accounting/ledgers/new", "/accounting/ledgers/#{ledger.id}", "/accounting/ledgers/#{ledger.id}/edit",
             "/vat/rates", "/vat/rates/new", "/vat/rates/#{rate.id}", "/vat/rates/#{rate.id}/edit", "/cards", "/cards/items",
             "/cards/new", "/cards/new?category=#{customer.id}", "/cards/#{card.id}", "/cards/#{card.id}/edit"]
    paths.each do |path|
      response = browser.get(path)
      response.status.should eq(200), "#{path} : #{response.status}"
      check_accessibility(response.html, path)
      response.html.should_not contain("translation missing")
    end
  end

  it "respecte les règles automatisables sur l'enrôlement" do
    created = PartiduoUi::Accounts.create(email: "bob@example.com", password: nil)
    browser = PartiduoUi::Browser.new
    browser.post("/invitation/#{created.invitation.token}")
    check_accessibility(browser.get("/account/enrollment").html, "/account/enrollment")
  end

  it "signale la page courante, relie les erreurs à leur champ et annonce les alertes" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/").html.should contain(%(aria-current="page"))
    refused = browser.post("/account/password", {"current_password" => PartiduoUi::Accounts::PASSWORD, "new_password" => "court", "confirmation" => "court"}).html
    refused.should contain(%(aria-invalid="true"))
    refused.should contain(%(id="pd-new-password-errors"))
    refused.should contain(%(aria-describedby="pd-password-rules pd-password-feedback pd-new-password-errors"))
    PartiduoUi::Browser.new.post("/login", {"email" => "x@example.com", "password" => "y"}).html.should contain(%(role="alert"))
  end
end

describe "Mise en page adaptée à trois tailles d'écran (ADR-005 D5)" do
  css = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "app.css"))

  it "prévoit ordinateur, tablette (menu repliable) et téléphone (barre non figée)" do
    css.should contain("@media (max-width: 1279.98px)")
    css.should contain(".pd-app.is-menu-collapsed .pd-side { display: none; }")
    css.should contain("@media (max-width: 767.98px)")
    css.should match(/@media \(max-width: 767\.98px\) \{[^@]*\.pd-top \{ position: static;/m)
    css.should match(/@media \(max-width: 767\.98px\) \{[^@]*\.pd-hide-s \{ display: none; \}/m)
  end

  it "garde des cibles tactiles de 44 px, un focus visible et respecte la réduction des animations" do
    css.should contain(".pd-touch { min-height: 44px; min-width: 44px; }")
    css.should contain(":focus-visible { outline: 2px solid var(--pd-focus); outline-offset: 2px; }")
    css.should contain("prefers-reduced-motion: reduce")
  end

  it "n'utilise que des propriétés logiques pour les marges et bordures latérales (ADR-005 D7)" do
    css.should_not match(/(margin|padding|border)-(left|right)\s*:/)
    css.should_not match(/text-align:\s*(left|right)/)
  end
end
