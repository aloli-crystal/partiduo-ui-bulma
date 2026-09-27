# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Liens à usage unique envoyés par courriel. La réponse est la même que
  # l'adresse soit connue ou non : seule la possession de l'adresse permet
  # d'utiliser le jeton (doc/api/auth.adoc du cœur).
  #
  # Le courriel part à l'adresse *enregistrée* (`TokenView#email`), jamais à
  # celle saisie, dans la langue de l'utilisateur ; le lien est bâti sur le
  # nom d'hôte configuré de l'instance (`TokenView#domain`), en `https://`,
  # jamais sur l'en-tête `Host` de la requête (D-UI-021).
  module TokenMail
    def self.send(token : Partiduo::Api::Auth::TokenView, route : String) : Nil
      link = "#{base_url(token.domain)}#{Marten.routes.reverse(route, token: token.token)}"
      locale = Locale.available.includes?(token.locale) ? token.locale : I18n.locale
      I18n.with_locale(locale) do
        TokenEmail.new(token.email, token.purpose, link, token.expires_at, Format.new(locale, token.country_code)).deliver
      end
    end

    # `https://<domaine>` ; seul un domaine de développement en `.localhost`
    # (contexte sécurisé sans HTTPS, ADR-002 D5) est servi en `http://`, sur
    # le port du serveur.
    def self.base_url(domain : String) : String
      host = domain.downcase
      if host == "localhost" || host.ends_with?(".localhost")
        port = Marten.settings.port
        "http://#{host}#{port == 80 ? "" : ":#{port}"}"
      else
        "https://#{host}"
      end
    end
  end

  class PasswordForgottenHandler < Handler
    def get
      page("ui/auth/request_link.html", {"kind" => "password_reset", "email" => ""})
    end

    def post
      email = field("email")
      # Même réponse au-delà de la limite : rien n'est révélé, rien n'est envoyé.
      token = RateLimit.allow?(request, "token_request") ? Partiduo::Api::Auth.request_password_reset(Partiduo::Api::Actor.anonymous, email) : nil
      if token
        TokenMail.send(token, "password_reset")
      end
      page("ui/auth/link_sent.html", {"kind" => "password_reset"})
    end
  end

  class PasswordResetHandler < Handler
    def get
      reset_page
    end

    def post
      password = field("new_password", strip: false)
      if password != field("confirmation", strip: false)
        return reset_page(field_error("confirmation", "ui.password.mismatch"), 422)
      end
      result = Partiduo::Api::Auth.reset_password(Partiduo::Api::Actor.anonymous, params["token"].to_s, password)
      return reset_page(errors_of(result), 422) if result.failure?
      flash["success"] = I18n.t("ui.password.reset_done")
      go(reverse("login"))
    end

    private def reset_page(errors = {} of String => Array(String), status : Int32 = 200)
      page("ui/auth/password_reset.html", {
        "errors" => errors,
        "policy" => PasswordPolicy.hints,
      }, status)
    end
  end

  class UnlockRequestHandler < Handler
    def get
      page("ui/auth/request_link.html", {"kind" => "unlock", "email" => query("email")})
    end

    def post
      email = field("email")
      token = RateLimit.allow?(request, "token_request") ? Partiduo::Api::Auth.request_unlock(Partiduo::Api::Actor.anonymous, email) : nil
      if token
        TokenMail.send(token, "unlock")
      end
      page("ui/auth/link_sent.html", {"kind" => "unlock"})
    end
  end

  class UnlockHandler < Handler
    def get
      page("ui/auth/unlock.html", {"errors" => {} of String => Array(String)})
    end

    def post
      result = Partiduo::Api::Auth.unlock_with_token(Partiduo::Api::Actor.anonymous, params["token"].to_s)
      return page("ui/auth/unlock.html", {"errors" => errors_of(result)}, 422) if result.failure?
      flash["success"] = I18n.t("ui.unlock.done")
      go(reverse("login"))
    end
  end

  # Règles de mot de passe du cœur, en phrases pour l'aide à la saisie.
  module PasswordPolicy
    def self.hints : Array(String)
      policy = Partiduo::Api::Auth.password_policy(Partiduo::Api::Actor.anonymous)
      hints = [I18n.t("ui.password.hint_length", minimum: policy.minimum_length)]
      hints << I18n.t("ui.password.hint_uppercase") if policy.require_uppercase
      hints << I18n.t("ui.password.hint_lowercase") if policy.require_lowercase
      hints << I18n.t("ui.password.hint_digit") if policy.require_digit
      hints << I18n.t("ui.password.hint_special") if policy.require_special
      hints << I18n.t("ui.password.hint_personal")
      hints
    end
  end

  # Contrôle instantané d'un mot de passe (HTMX) : même règle que les
  # commandes qui l'enregistrent (`Api::Auth.check_password`).
  class PasswordCheckHandler < Handler
    def post
      session = current.session
      result = Partiduo::Api::Auth.check_password(Partiduo::Api::Actor.anonymous, field("new_password", strip: false),
        email: session.try(&.email) || "", first_name: session.try(&.full_name) || "")
      messages = result.failure? ? result.errors.map(&.message) : nil
      render("ui/account/_password_feedback.html", {"messages" => messages, "checked" => true})
    end
  end
end
