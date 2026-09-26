# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des handlers de l'interface : utilisateur courant, lecture des
  # formulaires, erreurs du contrat traduites, redirections compatibles HTMX.
  abstract class Handler < Marten::Handlers::Base
    before_dispatch :activate_user_locale

    rescue_from Partiduo::Api::AccessDenied do
      if error.is_a?(Partiduo::Api::Auth::ElevationRequired)
        flash["warning"] = I18n.t(error.as(Partiduo::Api::AccessDenied).key)
        Navigation.redirect(request, reverse("account_security"))
      else
        ErrorPage.render(request, current.authenticated? ? 403 : 401)
      end
    end

    rescue_from Partiduo::Api::NotFound do
      ErrorPage.render(request, 404)
    end

    def current : Current
      Current.for(request)
    end

    # Valeur d'un champ de formulaire, sans espaces autour pour les champs
    # qui n'en admettent pas (codes, adresses).
    def field(name : String, strip : Bool = true) : String
      value = request.data.fetch(name, nil).try(&.to_s) || ""
      strip ? value.strip : value
    end

    def query(name : String) : String
      request.query_params.fetch(name, nil).try(&.to_s) || ""
    end

    def htmx? : Bool
      Navigation.htmx?(request)
    end

    def go(url : String) : Marten::HTTP::Response
      Navigation.redirect(request, url)
    end

    # Erreurs d'un résultat du contrat, traduites, rangées par champ
    # (`base` pour l'ensemble) : `{"email" => ["…"], "base" => ["…"]}`.
    def errors_of(result) : Hash(String, Array(String))
      errors = {} of String => Array(String)
      result.errors.each { |error| (errors[error.field] ||= [] of String) << error.message }
      errors
    end

    def field_error(field : String, key : String, params = {} of String => String) : Hash(String, Array(String))
      {field => [I18n.t(key, params)]}
    end

    # Liste pour un gabarit : `nil` si elle est vide (pour Marten, une liste
    # vide est vraie dans un `{% if %}`).
    def listed(items : Array(T)) : Array(T)? forall T
      items.empty? ? nil : items
    end

    # Page complète ; `status` 422 pour un formulaire refusé.
    def page(template : String, values = {} of String => String, status : Int32 = 200) : Marten::HTTP::Response
      context["ui_path"] = request.full_path
      render(template, values, status: status)
    end

    private def activate_user_locale
      Locale.activate_for(request, current)
      nil
    end
  end

  # Écran de l'application, derrière la connexion : coquille (barre
  # supérieure, menu des modules actifs), contrôle du niveau de session.
  #
  # `screen_access` : `:full` (défaut, droits requis), `:account` (pages de
  # sécurité, ouvertes à une session sous le niveau exigé pour qu'elle
  # s'élève), `:enrollment` (ouvertes aussi à la session d'enrôlement).
  abstract class ScreenHandler < Handler
    before_dispatch :require_screen_access
    before_render :add_shell

    private def screen_access : Symbol
      :full
    end

    private def require_screen_access
      current = self.current
      return Navigation.to_login(request) unless current.authenticated?

      if current.enrollment?
        return go(reverse("account_enrollment")) unless screen_access == :enrollment
      elsif current.elevation_required? && screen_access == :full
        flash["warning"] = I18n.t("ui.security.elevation_needed")
        return go(reverse("account_security"))
      end
      nil
    end

    private def add_shell
      current = self.current
      return if current.enrollment? || !current.authenticated?
      context["shell"] = Shell.build(request, current)
      nil
    end
  end
end
