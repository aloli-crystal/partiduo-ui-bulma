# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Éléments communs des écrans du référentiel (listes, formulaires,
  # consultations) : fil d'Ariane, onglets, actions, rubriques de
  # consultation. Objets à attributs pour les gabarits (D-UI-010).
  module Screen
    # Liste vide → `nil` (une liste vide est vraie pour Marten, D-UI-010).
    def self.listed(items : Array(T)) : Array(T)? forall T
      items.empty? ? nil : items
    end

    class Crumb
      include Marten::Template::Object::Auto

      getter label : String
      getter url : String?

      def initialize(@label, @url = nil)
      end
    end

    class Tab
      include Marten::Template::Object::Auto

      getter label : String
      getter url : String
      getter current : Bool

      def initialize(@label, @url, @current = false)
      end
    end

    # Action d'en-tête ou de ligne : lien (`get`) ou bouton de formulaire
    # (`post`, jeton CSRF), avec confirmation facultative.
    class Action
      include Marten::Template::Object::Auto

      getter label : String
      getter url : String
      getter method : String
      getter style : String
      getter icon : String?
      getter confirm : String?

      def initialize(@label, @url, @method = "get", @style = "", @icon = nil, @confirm = nil)
      end

      def post : Bool
        method == "post"
      end

      def css : String
        case style
        when "primary" then "button is-primary pd-touch"
        when "danger"  then "button is-danger is-light pd-touch"
        when "small"   then "button is-small"
        else                "button pd-touch"
        end
      end
    end

    # Ligne d'une rubrique de consultation.
    class Item
      include Marten::Template::Object::Auto

      getter label : String
      getter value : String
      getter url : String?
      getter mono : Bool

      def initialize(@label, @value, @url = nil, @mono = false)
      end
    end

    # Rubrique de consultation : définitions, tableau ou note.
    class Section
      include Marten::Template::Object::Auto

      getter title : String
      getter items : Array(Item)?
      getter table : Table?
      getter note : String?
      getter actions : Array(Action)?

      def initialize(@title, items : Array(Item)? = nil, @table = nil, @note = nil, actions : Array(Action)? = nil)
        @items = items.try { |list| Screen.listed(list.reject(&.value.empty?)) }
        @actions = actions.try { |list| Screen.listed(list) }
      end

      # Identifiant du titre de la rubrique (`aria-labelledby`).
      def anchor : String
        "pd-section-" + Table.fold(title).gsub(/[^a-z0-9]+/, "-").strip('-')
      end
    end
  end
end
