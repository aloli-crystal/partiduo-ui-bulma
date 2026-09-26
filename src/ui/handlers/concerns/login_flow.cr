# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Suite commune des connexions réussies (mot de passe + second facteur,
  # passkey) : cookie de session, puis parcours d'élévation (ADR-002 D6) —
  # session sous le niveau exigé : page de sécurité ; connexion sans passkey :
  # invitation à en enrôler une (refusable, rappelée) ; sinon la page demandée.
  module LoginFlow
    def self.destination(request : Marten::HTTP::Request, view : Partiduo::Api::Auth::LoginView, next_path : String) : String
      Current.open(request, view.session_token!)
      if view.elevation_required
        request.flash["warning"] = I18n.t("ui.security.elevation_needed")
        Marten.routes.reverse("account_security")
      elsif view.suggest_passkey
        with_next(Marten.routes.reverse("account_passkey_prompt"), next_path)
      else
        next_path
      end
    end

    def self.with_next(url : String, next_path : String?) : String
      return url if next_path.nil? || next_path == Marten.routes.reverse("core:dashboard")
      "#{url}?#{URI::Params.encode({"next" => next_path})}"
    end

    # Précisions affichées avec un refus de connexion : temporisation
    # (secondes restantes) ou blocage (lien de déblocage) — CNIL 2022-100.
    def self.throttling(result) : Hash(String, String | Bool)
      details = {} of String => String | Bool
      result.errors.each do |error|
        case error.key
        when "auth.errors.login.throttled"
          details["throttled"] = true
          details["seconds"] = error.params["seconds"]? || ""
        when "auth.errors.login.locked"
          details["locked"] = true
        end
      end
      details
    end
  end
end
