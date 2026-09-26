# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Tableau de bord (route `core:dashboard` du manifeste du socle). Les tuiles
  # des modules actifs arrivent avec leurs écrans ; en attendant, l'écran
  # rappelle les modules actifs et l'état de sécurité du compte.
  class DashboardHandler < ScreenHandler
    def get
      actor = current.actor
      modules = Partiduo::Api::Modules.list(actor).select { |item| item.active && item.kind != "socle" }.map do |item|
        {"code" => item.code, "name_key" => item.name_key, "extension" => item.kind == "extension"}
      end
      overview = Partiduo::Api::Auth.security_overview(actor)
      page("ui/dashboard.html", {
        "modules"         => listed(modules),
        "suggest_passkey" => overview.suggest_passkey,
        "missing"         => listed(overview.missing.map { |item| "auth.missing.#{item}" }),
      })
    end
  end

  # À propos : version du contrat et démonstration Opal (lot P).
  class AboutHandler < ScreenHandler
    def get
      page("ui/about.html", {"api_version" => Partiduo::API_VERSION, "version" => PartiduoUi::VERSION})
    end
  end

  # Recherche globale de la barre supérieure. Le contrat n'expose pas encore
  # de recherche (comptes, fiches, pièces : lots 1 et 2) : l'écran le dit.
  class SearchHandler < ScreenHandler
    def get
      page("ui/search.html", {"q" => query("q").presence})
    end
  end
end
