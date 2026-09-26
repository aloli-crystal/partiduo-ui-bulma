# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Connexion (ADR-002) : la passkey d'abord, puis le mot de passe (suivi du
  # TOTP ou d'un code de récupération si l'utilisateur a un second facteur).
  # Refus, temporisation et blocage sont affichés tels que le cœur les décide.
  class LoginHandler < Handler
    def get
      if current.authenticated? && !current.enrollment?
        return go(Navigation.next_path(request))
      end
      login_page
    end

    # Étape 1 du mot de passe.
    def post
      email = field("email")
      input = Partiduo::Api::Auth::PasswordLoginInput.new(email, field("password", strip: false), Current.login_context(request))
      result = Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous, input)
      return login_page(email, errors_of(result), LoginFlow.throttling(result), 422) if result.failure?

      view = result.value!
      next_path = Navigation.next_path(request)
      if view.authenticated?
        return go(LoginFlow.destination(request, view, next_path))
      end

      request.cookies.set(Current::PENDING_COOKIE, view.pending_token!, expires: 10.minutes.from_now,
        http_only: true, secure: request.secure?, same_site: "Lax")
      params = {"factors" => view.second_factors.join(',')}
      params["next"] = next_path unless next_path == reverse("core:dashboard")
      go("#{reverse("login_second_factor")}?#{URI::Params.encode(params)}")
    end

    private def login_page(email : String = "", errors = {} of String => Array(String),
                           throttling = {} of String => String | Bool, status : Int32 = 200)
      page("ui/auth/login.html", {
        "email"      => email,
        "errors"     => errors,
        "throttling" => throttling,
        "next"       => Navigation.safe_path(query("next").presence || field("next").presence) || "",
        "company"    => company_name,
      }, status)
    end

    # Nom du dossier sur l'écran de connexion : le contrat ne l'expose qu'à un
    # utilisateur authentifié ; l'écran affiche donc le nom de l'hôte.
    private def company_name : String
      request.host
    end
  end

  # Étape 2 : code de l'application d'authentification, ou code de récupération.
  class LoginSecondFactorHandler < Handler
    def get
      return go(reverse("login")) if pending_token.nil?
      form_page
    end

    def post
      token = pending_token
      if token.nil?
        flash["warning"] = I18n.t("auth.errors.login.expired")
        return go(reverse("login"))
      end

      kind = field("kind") == "recovery_code" ? "recovery_code" : "totp"
      input = Partiduo::Api::Auth::SecondFactorInput.new(token, field("code").delete(' '), kind, Current.login_context(request))
      result = Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous, input)
      if result.failure?
        if result.error_keys.includes?("auth.errors.login.expired")
          request.cookies.delete(Current::PENDING_COOKIE, same_site: "Lax")
          flash["warning"] = I18n.t("auth.errors.login.expired")
          return go(reverse("login"))
        end
        return form_page(errors_of(result), LoginFlow.throttling(result), kind, 422)
      end

      request.cookies.delete(Current::PENDING_COOKIE, same_site: "Lax")
      go(LoginFlow.destination(request, result.value!, Navigation.next_path(request)))
    end

    private def pending_token : String?
      request.cookies[Current::PENDING_COOKIE]?.presence
    end

    private def form_page(errors = {} of String => Array(String), throttling = {} of String => String | Bool,
                          kind : String = "totp", status : Int32 = 200)
      factors = (query("factors").presence || field("factors").presence || "totp,recovery_code").split(',')
      page("ui/auth/second_factor.html", {
        "errors"     => errors,
        "throttling" => throttling,
        "kind"       => kind,
        "totp"       => factors.includes?("totp"),
        "recovery"   => factors.includes?("recovery_code"),
        "factors"    => factors.join(','),
        "next"       => Navigation.safe_path(query("next").presence || field("next").presence) || "",
      }, status)
    end
  end

  # Connexion par passkey (credential découvrable, sans identifiant saisi) :
  # options pour `navigator.credentials.get()`, puis vérification.
  class LoginPasskeyOptionsHandler < Handler
    def post
      json(PasskeyJson.request(Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)))
    end
  end

  class LoginPasskeyHandler < Handler
    def post
      input = PasskeyJson.assertion(request.data, Current.login_context(request))
      result = Partiduo::Api::Auth.login_passkey(Partiduo::Api::Actor.anonymous, input)
      if result.failure?
        return json(PasskeyJson.outcome(false, error: result.errors.map(&.message).join(' ')), 422)
      end
      json(PasskeyJson.outcome(true, redirect: LoginFlow.destination(request, result.value!, Navigation.next_path(request))))
    end
  end

  class LogoutHandler < Handler
    def post
      Current.close(request)
      flash["success"] = I18n.t("ui.login.logged_out")
      go(reverse("login"))
    end
  end

  # Invitation (ADR-002 D6, D7) : le lien reçu par courriel ouvre une session
  # d'enrôlement. Un GET ne consomme rien (aperçus de liens, antivirus) : il
  # affiche un bouton qui confirme.
  class InvitationHandler < Handler
    def get
      page("ui/auth/invitation.html", {"errors" => {} of String => Array(String)})
    end

    def post
      result = Partiduo::Api::Auth.accept_invitation(Partiduo::Api::Actor.anonymous, params["token"].to_s,
        Current.login_context(request))
      return page("ui/auth/invitation.html", {"errors" => errors_of(result)}, 422) if result.failure?
      Current.open(request, result.value!.session_token!)
      go(reverse("account_enrollment"))
    end
  end

  # Langue de l'interface, choisie dans la barre supérieure : cookie de
  # langue de Marten, prioritaire sur la langue du navigateur.
  class LanguageHandler < Handler
    def post
      locale = field("locale")
      if Locale.available.includes?(locale)
        request.cookies.set(Marten.settings.i18n.locale_cookie_name, locale, expires: 1.year.from_now,
          same_site: "Lax", secure: request.secure?)
      end
      go(Navigation.next_path(request, reverse("login")))
    end
  end
end
