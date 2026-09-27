# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Montage des interfaces d'extension sous `/ext/<CODE>/` et contrôle d'accès
  # *avant* le handler, à partir du manifeste (ADR-003 D3, ADR-005 D4).
  #
  # Le dossier `ui/bulma/` d'une extension déclare ses routes Marten et les
  # confie à l'interface :
  #
  # ```
  # module Skel::Ui
  #   ROUTES = Marten::Routing::Map.draw do
  #     path "/", Skel::Ui::IndexHandler, name: "index"
  #     path "/edit", Skel::Ui::EditHandler, name: "edit"
  #   end
  # end
  #
  # PartiduoUi::Extensions.mount "SKEL", Skel::Ui::ROUTES,
  #   permissions: {"edit" => "skel.page.edit"}
  # ```
  #
  # Les routes sont nommées `<code en minuscules>:<nom>` (`skel:index`) : ce
  # sont les noms que citent les menus du manifeste. Toute requête sous
  # `/ext/` passe par `PartiduoUi::ExtensionHandler`, qui décide avant
  # d'appeler le handler de l'extension :
  #
  # . utilisateur non connecté : redirection vers la connexion ;
  # . extension inconnue du registre, inactive, ou pièce qui n'est pas une
  #   extension : 404 (ADR-006 D2 : une pièce inactive n'existe pas pour
  #   l'utilisateur) ;
  # . session d'enrôlement ou sous le niveau exigé : redirection vers la page
  #   d'enrôlement ou de sécurité du compte (ADR-002 D6) ;
  # . permission de la route : celle donnée au montage (`permissions` par
  #   route, sinon `permission` pour toutes), qui doit être déclarée par le
  #   manifeste de l'extension ; à défaut, celle de l'entrée de menu du
  #   manifeste qui porte cette route (la route est permise si elle figure
  #   dans le menu de l'utilisateur, `Partiduo::Api::Modules.menu`) ;
  # . sinon : refus (403). Une route que ni le montage ni le manifeste ne
  #   couvrent n'est jamais ouverte par défaut.
  module Extensions
    PREFIX = "/ext/"

    # Interface d'une extension, montée sous `/ext/<code>/`.
    record Mount, code : String, routes : Marten::Routing::Map, permission : String?,
      permissions : Hash(String, String) do
      # Préfixe des noms de route : `skel` pour `SKEL`.
      def namespace : String
        code.downcase
      end

      def path : String
        "#{PREFIX}#{code}"
      end

      # Permission donnée au montage pour une route (nom complet `skel:edit`).
      def permission_for(route_name : String?) : String?
        route_name.try { |name| permissions[name]? } || permission
      end
    end

    # Issue du contrôle d'accès.
    enum Decision
      Allowed
      Login
      NotFound
      Forbidden
      Enrollment
      Elevation
    end

    @@mounts = {} of String => Mount
    @@drawn = Set(String).new

    # Déclare l'interface d'une extension. `permission` : permission exigée
    # pour toutes ses routes ; `permissions` : par nom de route (court,
    # `"edit"`, ou complet, `"skel:edit"`).
    def self.mount(code : String, routes : Marten::Routing::Map, permission : String? = nil,
                   permissions : Hash(String, String) = {} of String => String) : Mount
      unless code.matches?(/\A[A-Z][A-Z0-9_]*\z/)
        raise ArgumentError.new("code d'extension invalide (majuscules, chiffres, _) : #{code}")
      end
      raise ArgumentError.new("interface d'extension déjà montée : #{code}") if @@mounts.has_key?(code)

      namespace = code.downcase
      qualified = permissions.to_h do |route, name|
        {route.includes?(':') ? route : "#{namespace}:#{route}", name}
      end
      @@mounts[code] = Mount.new(code, routes, permission, qualified)
    end

    def self.mounts : Array(Mount)
      @@mounts.values
    end

    def self.[]?(code : String) : Mount?
      @@mounts[code]?
    end

    # Compteur d'une entrée de menu d'extension (ADR-005 D8 : nombre de
    # justificatifs à traiter) : affiché à côté de l'entrée du menu et, s'il
    # est positif, repris dans « À traiter » du tableau de bord
    # (`todo` : clé i18n à pluriel, paramètre `count` ; `route` : écran
    # ouvert par la ligne). Le bloc lit le contrat de l'extension et rend
    # `nil` quand l'acteur ne doit rien voir (extension inactive, sans droit).
    record Counter, menu_code : String, route : String, todo : String?, tone : String,
      block : Proc(Partiduo::Api::Actor, Int64?)

    @@counters = {} of String => Counter

    def self.counter(menu_code : String, route : String, todo : String? = nil, tone : String = "primary",
                     &block : Partiduo::Api::Actor -> Int64?) : Counter
      @@counters[menu_code] = Counter.new(menu_code, route, todo, tone, block)
    end

    def self.counters : Array(Counter)
      @@counters.values
    end

    # Valeurs des compteurs pour l'acteur, par code d'entrée de menu ; un
    # compteur refusé (droit, module inactif) est omis.
    def self.counts(actor : Partiduo::Api::Actor) : Hash(String, Int64)
      @@counters.each_value.with_object({} of String => Int64) do |counter, counts|
        value = begin
          counter.block.call(actor)
        rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
          nil
        end
        counts[counter.menu_code] = value if value
      end
    end

    # Ajoute aux routes de l'interface celles des extensions montées (appelé
    # par `PartiduoUi::App#setup`, avant la préparation des routes par Marten).
    def self.draw(map : Marten::Routing::Map = Marten.routes) : Nil
      @@mounts.each_value do |mount|
        next if @@drawn.includes?(mount.code)
        map.path mount.path, mount.routes, name: mount.namespace
        @@drawn << mount.code
      end
    end

    # Interface d'extension visée par un chemin, et nom complet de la route
    # (`nil` si aucune route de l'extension ne correspond).
    def self.match(path : String) : {Mount, String?}?
      return unless path.starts_with?(PREFIX)
      code = path[PREFIX.size..].split('/', 2).first
      mount = @@mounts[code]?
      return if mount.nil?
      {mount, route_name(mount.routes, path[mount.path.size..], mount.namespace)}
    end

    # Nom complet de la route d'une carte qui correspond au chemin.
    def self.route_name(map : Marten::Routing::Map, path : String, prefix : String) : String?
      map.rules.each do |rule|
        case rule
        when Marten::Routing::Rule::Path
          return "#{prefix}:#{rule.name}" if rule.resolve(path)
        when Marten::Routing::Rule::Map
          nested = rule.path
          if nested.is_a?(String) && !nested.includes?('<') && path.starts_with?(nested)
            if found = route_name(rule.map, path[nested.size..], rule.name.empty? ? prefix : "#{prefix}:#{rule.name}")
              return found
            end
          end
        end
      end
      nil
    end

    # Contrôle d'accès à une route d'extension (voir l'en-tête du module).
    def self.authorize(current : Current, mount : Mount, route_name : String?) : Decision
      return Decision::Login unless current.authenticated?
      actor = current.actor

      view = begin
        Partiduo::Api::Modules.get(actor, mount.code)
      rescue Partiduo::Api::NotFound
        return Decision::NotFound
      end
      return Decision::NotFound unless view.kind == "extension" && view.active
      return Decision::Enrollment if current.enrollment?
      return Decision::Elevation if current.elevation_required?

      if permission = mount.permission_for(route_name)
        # Une permission que le manifeste ne déclare pas ne donne aucun accès.
        return Decision::Forbidden unless view.permissions.includes?(permission)
        return actor.can?(permission) ? Decision::Allowed : Decision::Forbidden
      end

      return Decision::Forbidden if route_name.nil?
      menu_routes(Partiduo::Api::Modules.menu(actor)).includes?(route_name) ? Decision::Allowed : Decision::Forbidden
    end

    # Routes des entrées de menu visibles, à tout niveau de l'arbre.
    def self.menu_routes(entries : Array(Partiduo::Api::Modules::MenuView), into = Set(String).new) : Set(String)
      entries.each do |entry|
        entry.route.try { |route| into << route }
        menu_routes(entry.children, into)
      end
      into
    end
  end
end
