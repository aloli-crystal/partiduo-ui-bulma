# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Mode simplifié (ADR-007 D3, DECISIONS D-UI-061, D-UI-069) : quand le
  # module `MICRO` (micro-entreprise) ou `LIBERAL` (profession libérale,
  # ADR-007 D6) est actif et que l'utilisateur peut lire ses registres,
  # l'interface présente un menu réduit, un tableau de bord centré sur
  # l'essentiel de l'activité et un vocabulaire courant (« encaissé »,
  # « dépensé »). Les deux modules actifs à la fois : la micro-entreprise
  # l'emporte (ordre de `FLAVORS`).
  #
  # L'interface appliquée suit la *préférence de chaque utilisateur*,
  # enregistrée par le cœur avec son compte (`Partiduo::Api::Auth.preferences`,
  # DECISIONS D-UI-077, D-AUTH-016) : « Recettes et dépenses » ou mode
  # simplifié (`simple`), « Comptabilité » ou mode complet (`full`). Tant
  # que la personne n'a rien choisi, défaut de son rôle : `simple` pour un
  # utilisateur de la société, `full` pour le comptable (rôle `accountant`,
  # ADR-002 D4). Elle la règle dans ses préférences (`/account/preferences`)
  # ou par le raccourci de son menu, qui l'enregistre de même.
  #
  # Interfaces offertes (`interfaces`) : pour la profession libérale, la
  # comptabilité seulement si le module Comptabilité est actif ; pour la
  # micro-entreprise, le mode complet au seul comptable (ses utilisateurs de
  # la société restent en mode simplifié, ADR-007 D3). Une préférence qui
  # n'est pas offerte laisse l'interface simplifiée, sans être effacée : elle
  # revient avec le module. Le mode ne change que la présentation : les
  # droits restent ceux du contrat (`Partiduo::Api`), toute route permise
  # reste joignable.
  module SimpleMode
    MODULE     = "MICRO"
    READ       = "micro.register.read"
    ROLE       = "accountant"
    LIBERAL    = "LIBERAL"
    ACCOUNTING = "ACCOUNTING"
    SIMPLE     = Partiduo::Api::Auth::INTERFACE_SIMPLE
    FULL       = Partiduo::Api::Auth::INTERFACE_FULL

    # Entrée du menu réduit : code de menu d'un manifeste (présent dans le
    # menu de l'utilisateur, donc module actif et permission accordée),
    # libellé du mode simplifié, route servie par l'interface à la place de
    # celle du manifeste (`nil` : celle du manifeste).
    record Entry, code : String, label_key : String, route : String? = nil

    # Menu réduit de la micro-entreprise, dans l'ordre d'ADR-007 D3.
    MENU = [
      Entry.new("DASHBOARD", "ui.micro.menu.dashboard"),
      Entry.new("MICRO_RECEIPTS", "ui.micro.menu.receipts"),
      Entry.new("MICRO_PURCHASES", "ui.micro.menu.purchases"),
      Entry.new("INV_DOCUMENTS", "ui.micro.menu.invoices"),
      Entry.new("MICRO_URSSAF", "ui.micro.menu.urssaf"),
      Entry.new("DOCUMENT_INBOX", "ui.micro.menu.documents"),
    ]

    # Menu réduit de la profession libérale (ADR-007 D6) : le livre-journal
    # unique du manifeste se présente en deux entrées, recettes et dépenses.
    LIBERAL_MENU = [
      Entry.new("DASHBOARD", "ui.liberal.menu.dashboard"),
      Entry.new("LIBERAL_JOURNAL", "ui.liberal.menu.receipts", "liberal:receipts"),
      Entry.new("LIBERAL_JOURNAL", "ui.liberal.menu.expenses", "liberal:expenses"),
      Entry.new("LIBERAL_ASSETS", "ui.liberal.menu.assets"),
      Entry.new("INV_DOCUMENTS", "ui.liberal.menu.invoices"),
      Entry.new("LIBERAL_TAX_RETURN", "ui.liberal.menu.tax_return"),
      Entry.new("DOCUMENT_INBOX", "ui.liberal.menu.documents"),
    ]

    # Modules qui offrent le mode simplifié : permission de lecture des
    # registres, menu réduit, route des paramètres, permission des
    # paramètres, libellé des paramètres.
    record Flavor, module_code : String, read : String, menu : Array(Entry), settings_route : String,
      settings_permission : String, settings_label : String

    FLAVORS = [
      Flavor.new("MICRO", READ, MENU, "micro:settings", "micro.settings.write", "ui.micro.settings.title"),
      Flavor.new("LIBERAL", "liberal.register.read", LIBERAL_MENU, "liberal:settings", "liberal.settings.write",
        "ui.liberal.settings.title"),
    ]

    # Choix d'interface de l'utilisateur de la requête : module du mode
    # simplifié (`flavor`), interfaces offertes, préférence en vigueur
    # (celle qu'il a choisie ou le défaut de son rôle).
    record Choice, flavor : Flavor, interfaces : Array(String), preferences : Partiduo::Api::Auth::PreferencesView do
      # Interface appliquée : la préférence si elle est offerte, sinon
      # l'interface simplifiée.
      def applied : String
        SimpleMode.choose(preferences.interface, interfaces)
      end

      # Plus d'une interface offerte : la personne peut passer de l'une à
      # l'autre.
      def switchable? : Bool
        interfaces.size > 1
      end

      # Libellé d'une interface, dans le vocabulaire du module.
      def label_key(interface : String) : String
        "ui.preferences.#{flavor.module_code == LIBERAL ? "liberal" : "micro"}_#{interface}"
      end
    end

    # Module du mode simplifié offert à cet acteur (module actif, lecture
    # des registres), `nil` s'il n'y en a pas.
    def self.flavor(actor : Partiduo::Api::Actor) : Flavor?
      flavor(actor, active_modules(actor))
    end

    private def self.flavor(actor : Partiduo::Api::Actor, active : Set(String)) : Flavor?
      return unless actor.authenticated?
      FLAVORS.find { |item| active.includes?(item.module_code) && actor.can?(item.read) }
    end

    private def self.active_modules(actor : Partiduo::Api::Actor) : Set(String)
      return Set(String).new unless actor.authenticated?
      Partiduo::Api::Modules.list(actor).select(&.active).map(&.code).to_set
    rescue Partiduo::Api::AccessDenied
      Set(String).new
    end

    # Le mode simplifié s'offre-t-il à cet acteur ?
    def self.available?(actor : Partiduo::Api::Actor) : Bool
      !flavor(actor).nil?
    end

    # Choix d'interface de la requête, `nil` sans mode simplifié offert
    # (aucun module `MICRO` ou `LIBERAL` lisible) ; calculé une seule fois.
    def self.choice(request : Marten::HTTP::Request) : Choice?
      cached = request.partiduo_interface_choice
      return cached.as?(Choice) unless cached.nil?
      value = compute_choice(Current.for(request))
      request.partiduo_interface_choice = value || false
      value
    end

    private def self.compute_choice(current : Current) : Choice?
      return unless current.authenticated?
      actor = current.actor
      active = active_modules(actor)
      chosen = flavor(actor, active) || return
      Choice.new(chosen, interfaces(chosen.module_code, current.session.try(&.role), active.includes?(ACCOUNTING)),
        Partiduo::Api::Auth.preferences(actor))
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Module du mode simplifié de la requête (`MICRO`, `LIBERAL`), `nil` en
    # mode complet.
    def self.mode(request : Marten::HTTP::Request) : String?
      choice(request).try { |item| item.flavor.module_code if item.applied == SIMPLE }
    end

    def self.enabled?(request : Marten::HTTP::Request) : Bool
      !mode(request).nil?
    end

    # Interfaces offertes, à part pour les specs : profession libérale, la
    # comptabilité avec le module Comptabilité actif ; micro-entreprise, le
    # mode complet au seul comptable.
    def self.interfaces(module_code : String, role : String?, accounting_active : Bool) : Array(String)
      offered = module_code == LIBERAL ? accounting_active : role == ROLE
      offered ? [SIMPLE, FULL] : [SIMPLE]
    end

    # Interface appliquée, à part pour les specs : la préférence si elle est
    # offerte, sinon l'interface simplifiée (la préférence n'est pas effacée).
    def self.choose(preference : String, interfaces : Array(String)) : String
      interfaces.includes?(preference) ? preference : SIMPLE
    end

    # Raccourci du menu de l'utilisateur : interface vers laquelle il bascule
    # (`simple` ou `full`), `nil` s'il n'a pas le choix.
    def self.switch_target(request : Marten::HTTP::Request) : String?
      item = choice(request) || return
      return unless item.switchable?
      item.applied == SIMPLE ? FULL : SIMPLE
    end

    # Clé du libellé du raccourci vers `target` : vocabulaire du module
    # (« Passer à la comptabilité » pour la profession libérale).
    def self.switch_label(request : Marten::HTTP::Request, target : String) : String
      code = choice(request).try(&.flavor.module_code)
      scope = code == LIBERAL ? "ui.liberal.mode" : "ui.micro.mode"
      "#{scope}.#{target == SIMPLE ? "to_simple" : "to_full"}"
    end

    # Paramètres du module du mode simplifié (menu de l'utilisateur) : URL
    # et libellé, si l'acteur peut les modifier.
    def self.settings_link(module_code : String, actor : Partiduo::Api::Actor) : {String, String}?
      item = FLAVORS.find(&.module_code.==(module_code)) || return
      return unless actor.can?(item.settings_permission)
      url = Shell.resolve(item.settings_route) || return
      {url, item.settings_label}
    end

    # Menu réduit : entrées du menu de l'utilisateur retenues par le menu
    # du module (`MENU`, `LIBERAL_MENU`), dans son ordre, sans rubrique.
    def self.sections(menu : Array(Partiduo::Api::Modules::MenuView), path : String,
                      counts : Hash(String, Int64) = {} of String => Int64,
                      module_code : String = MODULE) : Array(Shell::Section)
      entries = flatten(menu).to_h { |entry| {entry.code, entry} }
      reduced = FLAVORS.find(&.module_code.==(module_code)).try(&.menu) || MENU
      items = reduced.compact_map do |wanted|
        entry = entries[wanted.code]? || next
        url = Shell.resolve(wanted.route || entry.route)
        next if url.nil?
        Shell::Item.new(wanted.code, wanted.label_key, url,
          Shell.active?(url, path), nil, counts[wanted.code]?)
      end
      [Shell::Section.new("SIMPLE", nil, items)]
    end

    private def self.flatten(menu : Array(Partiduo::Api::Modules::MenuView)) : Array(Partiduo::Api::Modules::MenuView)
      menu.flat_map { |entry| [entry] + flatten(entry.children) }
    end
  end
end
