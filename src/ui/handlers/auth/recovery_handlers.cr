# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Liens à usage unique envoyés par courriel. La réponse est la même que
  # l'adresse soit connue ou non : seule la possession de l'adresse permet
  # d'utiliser le jeton (doc/api/auth.adoc du cœur).
  module TokenMail
    def self.send(request : Marten::HTTP::Request, email : String, token : Partiduo::Api::Auth::TokenView, route : String) : Nil
      link = "#{request.scheme}://#{request.headers["Host"]? || request.host}#{Marten.routes.reverse(route, token: token.token)}"
      TokenEmail.new(email, token.purpose, link, token.expires_at).deliver
    end
  end

  class PasswordForgottenHandler < Handler
    def get
      page("ui/auth/request_link.html", {"kind" => "password_reset", "email" => ""})
    end

    def post
      email = field("email")
      if token = Partiduo::Api::Auth.request_password_reset(Partiduo::Api::Actor.anonymous, email)
        TokenMail.send(request, email, token, "password_reset")
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
      if token = Partiduo::Api::Auth.request_unlock(Partiduo::Api::Actor.anonymous, email)
        TokenMail.send(request, email, token, "unlock")
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
