# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Enrôlement ouvert par une invitation (session de niveau 0) : la passkey
  # est proposée d'abord, le mot de passe en repli (ADR-002 D6).
  class EnrollmentHandler < AccountHandler
    private def screen_access : Symbol
      :enrollment
    end

    def get
      return go(reverse("account_security")) unless current.enrollment?
      enrollment_page
    end

    # Repli : choisir un mot de passe. La session d'enrôlement est fermée ;
    # l'utilisateur se connecte avec son nouveau mot de passe.
    def post
      return go(reverse("account_security")) unless current.enrollment?
      password = field("new_password", strip: false)
      if password != field("confirmation", strip: false)
        return enrollment_page(field_error("confirmation", "ui.password.mismatch"), 422)
      end
      result = Partiduo::Api::Auth.change_password(current.actor, Partiduo::Api::Auth::ChangePasswordInput.new(password))
      return enrollment_page(errors_of(result), 422) if result.failure?
      Current.close(request)
      flash["success"] = I18n.t("ui.enrollment.password_done")
      go(reverse("login"))
    end

    private def enrollment_page(errors = {} of String => Array(String), status : Int32 = 200)
      page("ui/account/enrollment.html", {
        "errors" => errors,
        "failed" => !errors.empty?,
        "policy" => PasswordPolicy.hints,
        "user"   => {"name" => current.session!.full_name, "email" => current.session!.email},
      }, status)
    end
  end

  # Enrôlement d'une passkey : options de `navigator.credentials.create()`
  # puis enregistrement (JSON, `passkey.js`). Ouvert aussi à la session
  # d'enrôlement. On n'enrôle jamais une passkey seule : les codes de
  # récupération générés par le cœur sont affichés une seule fois (ADR-002 D7).
  class PasskeyRegistrationOptionsHandler < AccountHandler
    private def screen_access : Symbol
      :enrollment
    end

    def post
      json(PasskeyJson.creation(Partiduo::Api::Auth.begin_passkey_registration(current.actor)))
    end
  end

  class PasskeyRegistrationHandler < AccountHandler
    private def screen_access : Symbol
      :enrollment
    end

    def post
      result = Partiduo::Api::Auth.finish_passkey_registration(current.actor, PasskeyJson.registration(request.data))
      if result.failure?
        return json(PasskeyJson.outcome(false, error: result.errors.map(&.message).join(' ')), 422)
      end

      codes = result.value!.recovery_codes
      if current.enrollment?
        # Session d'enrôlement : sans droit ; la connexion se fait ensuite
        # avec la passkey qui vient d'être créée.
        Current.close(request)
        flash["success"] = I18n.t("ui.enrollment.passkey_done")
        return json(PasskeyJson.outcome(true, redirect: reverse("login"))) if codes.empty?
        return json(PasskeyJson.outcome(true, html: fragment("ui/account/_recovery_codes.html",
          codes_values(codes, reverse("login")))))
      end

      flash["success"] = I18n.t("ui.security.passkey_added")
      return json(PasskeyJson.outcome(true, redirect: reverse("account_security"))) if codes.empty?
      json(PasskeyJson.outcome(true, html: fragment("ui/account/_recovery_codes.html",
        codes_values(codes, reverse("account_security")))))
    end
  end

  class PasskeyRenameHandler < AccountHandler
    def post
      result = Partiduo::Api::Auth.rename_passkey(current.actor, params["id"].to_s.to_i64, field("name"))
      flash[result.success? ? "success" : "danger"] =
        result.success? ? I18n.t("ui.security.passkey_renamed") : result.errors.map(&.message).join(' ')
      go(reverse("account_security"))
    end
  end

  class PasskeyRemoveHandler < AccountHandler
    def post
      result = Partiduo::Api::Auth.remove_passkey(current.actor, params["id"].to_s.to_i64)
      flash[result.success? ? "success" : "danger"] =
        result.success? ? I18n.t("ui.security.passkey_removed") : result.errors.map(&.message).join(' ')
      go(reverse("account_security"))
    end
  end

  # Invitation à enrôler une passkey après une connexion par mot de passe
  # (ADR-002 D6) : refusable, mais rappelée.
  class PasskeyPromptHandler < AccountHandler
    def get
      page("ui/account/passkey_prompt.html", {"next" => Navigation.next_path(request)})
    end

    def post
      Partiduo::Api::Auth.dismiss_passkey_prompt(current.actor)
      go(Navigation.next_path(request))
    end
  end

  # Enrôlement de l'application d'authentification (TOTP, RFC 6238 : SHA-1,
  # 6 chiffres, 30 s) : QR code *et* secret base32, sans nommer aucune
  # application (ADR-002).
  class TotpEnrollmentHandler < AccountHandler
    def get
      enrollment = Partiduo::Api::Auth.begin_totp_enrollment(current.actor)
      page("ui/account/totp.html", {
        "qr"      => Marten::Template::SafeString.new(QrSvg.render(enrollment.qr_code, I18n.t("ui.totp.qr_label"))),
        "secret"  => QrSvg.group(enrollment.secret_base32),
        "issuer"  => enrollment.issuer,
        "account" => enrollment.account,
        "digits"  => enrollment.digits.to_s,
        "period"  => enrollment.period.to_s,
        "errors"  => {} of String => Array(String),
      })
    end

    # Confirmation par un premier code. En HTMX, un code refusé ne remplace
    # que le message d'erreur : le QR code affiché reste valable. Sans
    # JavaScript, la page est reproposée avec un nouveau secret.
    def post
      result = Partiduo::Api::Auth.confirm_totp_enrollment(current.actor, field("code").delete(' '))
      if result.failure?
        return render("ui/account/_totp_feedback.html", {"errors" => errors_of(result)}) if htmx?
        flash["danger"] = result.errors.map(&.message).join(' ')
        return go(reverse("account_totp"))
      end

      flash["success"] = I18n.t("ui.totp.enabled")
      response = codes_page(result.value!.codes, reverse("account_security"))
      if htmx?
        response["HX-Retarget"] = "body"
        response["HX-Reswap"] = "innerHTML"
      end
      response
    end
  end

  class TotpDisableHandler < AccountHandler
    def post
      result = Partiduo::Api::Auth.disable_totp(current.actor, field("code").delete(' '))
      flash[result.success? ? "success" : "danger"] =
        result.success? ? I18n.t("ui.totp.disabled") : result.errors.map(&.message).join(' ')
      go(reverse("account_security"))
    end
  end
end
