# SPDX-License-Identifier: AGPL-3.0-or-later

# Écrans du socle, sous les noms de route que citent les menus des
# manifestes (`core:dashboard`) : le cœur n'a aucune route (ADR-005 D1).
CORE_ROUTES = Marten::Routing::Map.draw do
  path "/", PartiduoUi::DashboardHandler, name: "dashboard"
  # Exercices et périodes (lot 1) ; période de travail de la barre supérieure.
  path "/fiscal-years", PartiduoUi::FiscalYearsHandler, name: "fiscal_years"
  path "/fiscal-years/<id:int>", PartiduoUi::FiscalYearHandler, name: "fiscal_year"
  path "/fiscal-years/<id:int>/close", PartiduoUi::FiscalYearCloseHandler, name: "fiscal_year_close"
  path "/fiscal-years/<id:int>/delete", PartiduoUi::FiscalYearDeleteHandler, name: "fiscal_year_delete"
  path "/periods/<id:int>/close", PartiduoUi::PeriodCloseHandler, name: "period_close"
  path "/periods/<id:int>/reopen", PartiduoUi::PeriodReopenHandler, name: "period_reopen"
  path "/periods/<id:int>/delete", PartiduoUi::PeriodDeleteHandler, name: "period_delete"
  path "/period", PartiduoUi::CurrentPeriodHandler, name: "current_period"
end

# Fiches du socle : tiers, articles et services (menu `cards:index`).
CARDS_ROUTES = Marten::Routing::Map.draw do
  path "", PartiduoUi::CardsHandler, name: "index"
  path "/items", PartiduoUi::ItemsHandler, name: "items"
  path "/new", PartiduoUi::CardNewHandler, name: "new"
  path "/<id:int>", PartiduoUi::CardHandler, name: "show"
  path "/<id:int>/edit", PartiduoUi::CardEditHandler, name: "edit"
  path "/<id:int>/enable", PartiduoUi::CardEnableHandler, name: "enable"
  path "/<id:int>/delete", PartiduoUi::CardDeleteHandler, name: "delete"
end

# Taux de TVA du socle (menu `vat:rates`).
VAT_ROUTES = Marten::Routing::Map.draw do
  path "/rates", PartiduoUi::VatRatesHandler, name: "rates"
  path "/rates/new", PartiduoUi::VatRateNewHandler, name: "rate_new"
  path "/rates/<id:int>", PartiduoUi::VatRateHandler, name: "rate"
  path "/rates/<id:int>/edit", PartiduoUi::VatRateEditHandler, name: "rate_edit"
  path "/rates/<id:int>/delete", PartiduoUi::VatRateDeleteHandler, name: "rate_delete"
end

# Module Comptabilité : plan comptable et journaux (menus `accounting:chart`,
# `accounting:ledgers`). Module inactif : le contrat refuse, l'écran répond 404.
ACCOUNTING_ROUTES = Marten::Routing::Map.draw do
  path "/chart", PartiduoUi::ChartHandler, name: "chart"
  path "/chart/new", PartiduoUi::AccountNewHandler, name: "account_new"
  path "/chart/<id:int>", PartiduoUi::AccountShowHandler, name: "account"
  path "/chart/<id:int>/edit", PartiduoUi::AccountEditHandler, name: "account_edit"
  path "/chart/<id:int>/delete", PartiduoUi::AccountDeleteHandler, name: "account_delete"
  path "/ledgers", PartiduoUi::LedgersHandler, name: "ledgers"
  path "/ledgers/new", PartiduoUi::LedgerNewHandler, name: "ledger_new"
  path "/ledgers/<id:int>", PartiduoUi::LedgerHandler, name: "ledger"
  path "/ledgers/<id:int>/edit", PartiduoUi::LedgerEditHandler, name: "ledger_edit"
  path "/ledgers/<id:int>/delete", PartiduoUi::LedgerDeleteHandler, name: "ledger_delete"
end

Marten.routes.draw do
  path "", CORE_ROUTES, name: "core"
  path "/cards", CARDS_ROUTES, name: "cards"
  path "/vat", VAT_ROUTES, name: "vat"
  path "/accounting", ACCOUNTING_ROUTES, name: "accounting"

  # Connexion (ADR-002).
  path "/login", PartiduoUi::LoginHandler, name: "login"
  path "/login/second-factor", PartiduoUi::LoginSecondFactorHandler, name: "login_second_factor"
  path "/login/passkey/options", PartiduoUi::LoginPasskeyOptionsHandler, name: "login_passkey_options"
  path "/login/passkey", PartiduoUi::LoginPasskeyHandler, name: "login_passkey"
  path "/logout", PartiduoUi::LogoutHandler, name: "logout"
  path "/invitation/<token:str>", PartiduoUi::InvitationHandler, name: "invitation"
  path "/password/forgotten", PartiduoUi::PasswordForgottenHandler, name: "password_forgotten"
  path "/password/reset/<token:str>", PartiduoUi::PasswordResetHandler, name: "password_reset"
  path "/password/check", PartiduoUi::PasswordCheckHandler, name: "password_check"
  path "/unlock", PartiduoUi::UnlockRequestHandler, name: "unlock_request"
  path "/unlock/<token:str>", PartiduoUi::UnlockHandler, name: "unlock"
  path "/language", PartiduoUi::LanguageHandler, name: "language"

  # Compte : enrôlement, sécurité, élévation (ADR-002 D6, D7).
  path "/account/enrollment", PartiduoUi::EnrollmentHandler, name: "account_enrollment"
  path "/account/security", PartiduoUi::SecurityHandler, name: "account_security"
  path "/account/password", PartiduoUi::PasswordChangeHandler, name: "account_password"
  path "/account/totp", PartiduoUi::TotpEnrollmentHandler, name: "account_totp"
  path "/account/totp/disable", PartiduoUi::TotpDisableHandler, name: "account_totp_disable"
  path "/account/recovery-codes", PartiduoUi::RecoveryCodesHandler, name: "account_recovery_codes"
  path "/account/passkeys/options", PartiduoUi::PasskeyRegistrationOptionsHandler, name: "account_passkey_options"
  path "/account/passkeys", PartiduoUi::PasskeyRegistrationHandler, name: "account_passkeys"
  path "/account/passkeys/<id:int>/rename", PartiduoUi::PasskeyRenameHandler, name: "account_passkey_rename"
  path "/account/passkeys/<id:int>/delete", PartiduoUi::PasskeyRemoveHandler, name: "account_passkey_remove"
  path "/account/passkey-prompt", PartiduoUi::PasskeyPromptHandler, name: "account_passkey_prompt"
  path "/account/elevate/totp", PartiduoUi::ElevateTotpHandler, name: "account_elevate_totp"
  path "/account/elevate/passkey/options", PartiduoUi::ElevatePasskeyOptionsHandler, name: "account_elevate_passkey_options"
  path "/account/elevate/passkey", PartiduoUi::ElevatePasskeyHandler, name: "account_elevate_passkey"

  path "/search", PartiduoUi::SearchHandler, name: "search"
  path "/about", PartiduoUi::AboutHandler, name: "about"

  # Interfaces d'extension (ADR-003 D3) : toute requête sous /ext/<CODE>/
  # passe par le contrôle d'accès, qui appelle ensuite le handler de
  # l'extension. Les cartes de routes des extensions sont ajoutées par
  # PartiduoUi::App#setup, après ces deux règles : elles servent à nommer
  # les routes (`uitest:index`), jamais à les atteindre directement.
  path "/ext/<code:str>/", PartiduoUi::ExtensionHandler, name: "extension_root"
  path "/ext/<code:str>/<path:path>", PartiduoUi::ExtensionHandler, name: "extension"

  # Fichiers statiques servis par Marten : directement depuis les applications
  # en développement et en test ; en production, après `collectassets`, par le
  # middleware Marten::Middleware::AssetServing (config/settings/production.cr).
  if Marten.env.development? || Marten.env.test?
    path "#{Marten.settings.assets.url}<path:path>", Marten::Handlers::Defaults::Development::ServeAsset, name: "asset"
  end
end
