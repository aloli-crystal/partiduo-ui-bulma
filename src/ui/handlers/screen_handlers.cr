# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Tableau de bord (route `core:dashboard` du manifeste du socle) : tuiles
  # des modules actifs, dernières factures et écritures, « À traiter »
  # (`PartiduoUi::Dashboard`), état de sécurité du compte.
  class DashboardHandler < ScreenHandler
    def get
      actor = current.actor
      active = Partiduo::Api::Modules.list(actor).select(&.active).map(&.code).to_set
      overview = Partiduo::Api::Auth.security_overview(actor)
      # Mode simplifié de la micro-entreprise (ADR-007 D3) : tableau de bord
      # centré sur le chiffre d'affaires, les seuils et l'échéance URSSAF.
      simple = SimpleMode.enabled?(request)
      board = simple ? MicroDashboard.new(actor, fmt, active).build : Dashboard.new(actor, fmt, active).build
      # Compteurs des extensions (justificatifs à traiter…), en tête de « À traiter ».
      counts = Extensions.counts(actor)
      Extensions.counters.each do |counter|
        count = counts[counter.menu_code]?
        next if count.nil? || count.zero? || (todo = counter.todo).nil?
        board.todos.unshift(Dashboard::Todo.new(I18n.t(todo, count: count), nil, Shell.resolve(counter.route), counter.tone))
      end
      overview.missing.each do |item|
        board.add_todo(Dashboard::Todo.new(I18n.t("auth.missing.#{item}"), nil, reverse("account_security"), "warn"))
      end
      modules = Partiduo::Api::Modules.list(actor).select { |item| item.active && item.kind != "socle" }.map do |item|
        {"code" => item.code, "name_key" => item.name_key, "extension" => item.kind == "extension"}
      end
      page(simple ? "ui/micro/dashboard.html" : "ui/dashboard.html", {
        "board"           => board,
        "modules"         => listed(modules),
        "suggest_passkey" => overview.suggest_passkey,
        "secure"          => overview.missing.empty?,
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
