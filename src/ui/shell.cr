# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Coquille de l'écran (maquette de référence, ADR-005 D5) : barre supérieure
  # (dossier, exercice et période, recherche, langue, utilisateur) et menu
  # latéral par domaine. Tout vient de `Partiduo::Api` : le menu de
  # l'utilisateur (`Api::Modules.menu`, modules actifs et permissions), la
  # société (`Api::Core.settings`), la session (`Api::Auth.session`).
  class Shell
    include Marten::Template::Object::Auto

    # Une entrée du menu latéral. `url` nil : écran pas encore livré par
    # l'interface (entrée affichée, désactivée). `badge` : code d'extension.
    class Item
      include Marten::Template::Object::Auto

      getter code : String
      getter label_key : String
      getter url : String?
      getter active : Bool # ameba:disable Naming/QueryBoolMethods
      getter badge : String?

      def initialize(@code, @label_key, @url, @active, @badge)
      end

      def disabled : Bool
        url.nil?
      end
    end

    # Une rubrique : libellé (`nil` pour une entrée de premier niveau sans
    # rubrique, comme le tableau de bord) et ses entrées.
    class Section
      include Marten::Template::Object::Auto

      getter code : String
      getter label_key : String?
      getter items : Array(Item)

      def initialize(@code, @label_key, @items)
      end
    end

    getter sections : Array(Section)
    getter company_name : String?
    getter company_detail : String?
    getter user_name : String
    getter user_email : String
    getter user_initials : String
    getter user_role_key : String
    getter locale : String
    getter locales : Array(String)
    getter current_path : String

    def initialize(@sections, @company_name, @company_detail, @user_name, @user_email, @user_role_key,
                   @locale, @locales, @current_path)
      @user_initials = initials(@user_name.presence || @user_email)
    end

    # Exercice et période courants (ADR-005 D5). Le contrat n'expose pas
    # encore les exercices (lot 1) : la barre affiche « aucun exercice ».
    def fiscal_year : String?
      nil
    end

    def period : String?
      nil
    end

    def self.build(request : Marten::HTTP::Request, current : Current) : Shell
      actor = current.actor
      session = current.session!
      settings = begin
        Partiduo::Api::Core.settings(actor)
      rescue Partiduo::Api::NotFound
        nil
      end
      detail = settings.try do |values|
        parts = [] of String
        parts << "SIREN #{values.siren}" unless values.siren.empty?
        parts << values.vat_number if values.siren.empty? && !values.vat_number.empty?
        parts << I18n.t("ui.shell.regime", regime: values.tax_regime.upcase) unless values.tax_regime.empty?
        parts.join(" · ").presence
      end

      new(
        sections: sections(Partiduo::Api::Modules.menu(actor), extension_codes(actor), request.path),
        company_name: settings.try(&.company_name.presence),
        company_detail: detail,
        user_name: session.full_name,
        user_email: session.email,
        user_role_key: "auth.roles.#{session.role}",
        locale: I18n.locale,
        locales: Locale.available,
        current_path: request.full_path,
      )
    end

    # Rubriques du menu : d'abord les domaines, puis les extensions (ADR-005 D5).
    def self.sections(menu : Array(Partiduo::Api::Modules::MenuView), extensions : Set(String), path : String) : Array(Section)
      menu.compact_map do |entry|
        if entry.children.empty?
          url = resolve(entry.route)
          Section.new(entry.code, nil, [Item.new(entry.code, entry.label_key, url, active?(url, path), badge(entry, extensions))])
        else
          items = entry.children.map do |child|
            url = resolve(child.route)
            Item.new(child.code, child.label_key, url, active?(url, path), badge(child, extensions))
          end
          Section.new(entry.code, entry.label_key, items)
        end
      end
    end

    # URL d'un nom de route du manifeste ; `nil` si l'interface ne le
    # fournit pas encore (ou s'il attend des paramètres).
    def self.resolve(route : String?) : String?
      return if route.nil?
      Marten.routes.reverse(route)
    rescue Marten::Routing::Errors::NoReverseMatch
      nil
    end

    def self.active?(url : String?, path : String) : Bool
      return false if url.nil?
      url == "/" ? path == "/" : (path == url || path.starts_with?(url.rstrip('/') + "/"))
    end

    private def self.badge(entry : Partiduo::Api::Modules::MenuView, extensions : Set(String)) : String?
      extensions.includes?(entry.module_code) ? entry.module_code : nil
    end

    private def self.extension_codes(actor : Partiduo::Api::Actor) : Set(String)
      Partiduo::Api::Modules.list(actor).select(&.kind.==("extension")).map(&.code).to_set
    end

    private def initials(name : String) : String
      words = name.split(/[\s@._-]+/).reject(&.empty?)
      letters = words.size > 1 ? [words.first, words.last] : words.first(1)
      letters.map(&.[0].upcase).join
    end
  end
end
