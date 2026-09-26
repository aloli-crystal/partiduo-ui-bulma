# SPDX-License-Identifier: AGPL-3.0-or-later

# Écrans du socle, sous les noms de route que citent les menus des
# manifestes (`core:dashboard`) : le cœur n'a aucune route (ADR-005 D1).
CORE_ROUTES = Marten::Routing::Map.draw do
  path "/", PartiduoUi::DashboardHandler, name: "dashboard"
end

Marten.routes.draw do
  path "", CORE_ROUTES, name: "core"

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
