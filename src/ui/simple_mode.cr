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
  # Le mode complet reste accessible au comptable (rôle `accountant`,
  # ADR-002 D4) : il y est par défaut et peut passer d'un mode à l'autre
  # (cookie `partiduo_mode`). Pour la profession libérale, l'interface des
  # autres utilisateurs est un réglage du dossier (paramètres du module,
  # « Recettes et dépenses » ou « Comptabilité », DECISIONS D-UI-076,
  # D-LIB3-001), sans bascule personnelle. Le mode ne change que la
  # présentation : les droits restent ceux du contrat (`Partiduo::Api`),
  # toute route permise reste joignable.
  module SimpleMode
    COOKIE = "partiduo_mode"
    MODULE = "MICRO"
    READ   = "micro.register.read"
    ROLE   = "accountant"

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

    # Module du mode simplifié offert à cet acteur (module actif, lecture
    # des registres), `nil` s'il n'y en a pas.
    def self.flavor(actor : Partiduo::Api::Actor) : Flavor?
      return unless actor.authenticated?
      active = Partiduo::Api::Modules.list(actor).select(&.active).map(&.code).to_set
      FLAVORS.find { |item| active.includes?(item.module_code) && actor.can?(item.read) }
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Le mode simplifié s'offre-t-il à cet acteur ?
    def self.available?(actor : Partiduo::Api::Actor) : Bool
      !flavor(actor).nil?
    end

    # Module du mode simplifié de la requête (`MICRO`, `LIBERAL`), `nil` en
    # mode complet.
    def self.mode(request : Marten::HTTP::Request) : String?
      cached = request.partiduo_simple_mode
      return cached.presence unless cached.nil?
      current = Current.for(request)
      chosen = current.authenticated? ? flavor(current.actor) : nil
      value = chosen && choose(current.session.try(&.role), request.cookies[COOKIE]?,
        folder_simple?(chosen, current.actor)) ? chosen.module_code : ""
      request.partiduo_simple_mode = value
      value.presence
    end

    # Mode de la requête : pour un utilisateur de la société, celui du
    # dossier ; pour un comptable, seulement s'il l'a choisi.
    def self.enabled?(request : Marten::HTTP::Request) : Bool
      !mode(request).nil?
    end

    # Règle du choix, à part pour les specs : `role` de la session, valeur
    # du cookie (`simple`, `full` ou absente), réglage du dossier
    # (`folder_simple`). Le comptable suit son cookie, jamais le dossier ;
    # un autre utilisateur suit le dossier, jamais un cookie.
    def self.choose(role : String?, cookie : String?, folder_simple : Bool = true) : Bool
      role == ROLE ? cookie == "simple" : folder_simple
    end

    # Réglage du dossier : la profession libérale peut présenter la
    # comptabilité à tous ses utilisateurs (paramètres du module, interface
    # `accounting`, que le contrat ne rend qu'avec la Comptabilité active) ;
    # la micro-entreprise reste en mode simplifié.
    def self.folder_simple?(chosen : Flavor, actor : Partiduo::Api::Actor) : Bool
      return true unless chosen.module_code == Partiduo::Api::Liberal::MODULE_CODE
      !Partiduo::Api::Liberal.settings(actor).accounting_interface?
    rescue Partiduo::Api::AccessDenied
      true
    end

    # Seul le comptable passe d'un mode à l'autre ; mode proposé (`simple`
    # ou `full`), `nil` pour un autre utilisateur.
    def self.switch_target(request : Marten::HTTP::Request) : String?
      current = Current.for(request)
      return unless current.session.try(&.role) == ROLE && available?(current.actor)
      enabled?(request) ? "full" : "simple"
    end

    # Clé du libellé du bouton de bascule vers `target` : vocabulaire du
    # module (« Passer à la comptabilité » pour la profession libérale).
    def self.switch_label(request : Marten::HTTP::Request, target : String) : String
      current = Current.for(request)
      code = current.authenticated? ? flavor(current.actor).try(&.module_code) : nil
      scope = code == "LIBERAL" ? "ui.liberal.mode" : "ui.micro.mode"
      "#{scope}.#{target == "simple" ? "to_simple" : "to_full"}"
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
