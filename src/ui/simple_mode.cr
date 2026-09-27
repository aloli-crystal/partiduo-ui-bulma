# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Mode simplifié de la micro-entreprise (ADR-007 D3, DECISIONS D-UI-061) :
  # quand le module `MICRO` est actif et que l'utilisateur peut lire ses
  # registres, l'interface présente un menu réduit (Tableau de bord,
  # Recettes, Achats, Factures, URSSAF, Justificatifs), un tableau de bord
  # centré sur le chiffre d'affaires, les seuils et la prochaine échéance, et
  # un vocabulaire courant (« encaissé », « dépensé »).
  #
  # Le mode complet reste accessible au comptable (rôle `accountant`,
  # ADR-002 D4) : il y est par défaut et peut passer d'un mode à l'autre
  # (cookie `partiduo_mode`). Le mode ne change que la présentation : les
  # droits restent ceux du contrat (`Partiduo::Api`), toute route permise
  # reste joignable.
  module SimpleMode
    COOKIE = "partiduo_mode"
    MODULE = "MICRO"
    READ   = "micro.register.read"
    ROLE   = "accountant"

    # Entrées du menu réduit, dans l'ordre d'ADR-007 D3 : code de menu d'un
    # manifeste (celles des modules inactifs ou non permis sont absentes du
    # menu de l'utilisateur, donc omises), libellé du mode simplifié.
    MENU = {
      "DASHBOARD"       => "ui.micro.menu.dashboard",
      "MICRO_RECEIPTS"  => "ui.micro.menu.receipts",
      "MICRO_PURCHASES" => "ui.micro.menu.purchases",
      "INV_DOCUMENTS"   => "ui.micro.menu.invoices",
      "MICRO_URSSAF"    => "ui.micro.menu.urssaf",
      "DOCUMENT_INBOX"  => "ui.micro.menu.documents",
    }

    # Le mode simplifié s'offre-t-il à cet acteur (module actif, lecture des
    # registres) ?
    def self.available?(actor : Partiduo::Api::Actor) : Bool
      return false unless actor.authenticated? && actor.can?(READ)
      Partiduo::Api::Modules.list(actor).any? { |item| item.code == MODULE && item.active }
    rescue Partiduo::Api::AccessDenied
      false
    end

    # Mode de la requête : simplifié pour un utilisateur de la société ;
    # pour un comptable, seulement s'il l'a choisi.
    def self.enabled?(request : Marten::HTTP::Request) : Bool
      cached = request.partiduo_simple
      return cached unless cached.nil?
      current = Current.for(request)
      value = current.authenticated? && available?(current.actor) && choose(current.session.try(&.role), request.cookies[COOKIE]?)
      request.partiduo_simple = value
      value
    end

    # Règle du choix, à part pour les specs : `role` de la session, valeur
    # du cookie (`simple`, `full` ou absente).
    def self.choose(role : String?, cookie : String?) : Bool
      role == ROLE ? cookie == "simple" : true
    end

    # Le comptable peut passer d'un mode à l'autre ; mode proposé
    # (`simple` ou `full`), `nil` pour un autre utilisateur.
    def self.switch_target(request : Marten::HTTP::Request) : String?
      current = Current.for(request)
      return unless current.session.try(&.role) == ROLE && available?(current.actor)
      enabled?(request) ? "full" : "simple"
    end

    # Menu réduit : entrées du menu de l'utilisateur retenues par `MENU`,
    # dans son ordre, sans rubrique.
    def self.sections(menu : Array(Partiduo::Api::Modules::MenuView), path : String,
                      counts : Hash(String, Int64) = {} of String => Int64) : Array(Shell::Section)
      entries = flatten(menu).to_h { |entry| {entry.code, entry} }
      items = MENU.compact_map do |code, label_key|
        entry = entries[code]? || next
        url = Shell.resolve(entry.route)
        next if url.nil?
        Shell::Item.new(code, label_key, url, Shell.active?(url, path), nil, counts[code]?)
      end
      [Shell::Section.new("SIMPLE", nil, items)]
    end

    private def self.flatten(menu : Array(Partiduo::Api::Modules::MenuView)) : Array(Partiduo::Api::Modules::MenuView)
      menu.flat_map { |entry| [entry] + flatten(entry.children) }
    end
  end
end
