# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Formulaire d'un écran du référentiel, décrit par le handler et rendu par
  # `ui/_form_fields.html` (DECISIONS D-UI-016). Les erreurs du contrat
  # (`FieldError`, déjà traduites) sont rangées sous leur champ ; celles qui
  # ne correspondent à aucun champ affiché vont à l'ensemble du formulaire.
  class Form
    include Marten::Template::Object::Auto

    class Option
      include Marten::Template::Object::Auto

      getter value : String
      getter label : String
      getter selected : Bool

      def initialize(@value, @label, @selected = false)
      end
    end

    # Champ : `type` `text`, `number` (décimal saisi en texte), `date`,
    # `email`, `password` (secret jamais réaffiché), `select`, `checkbox`,
    # `textarea`, `hidden`.
    class Field
      include Marten::Template::Object::Auto

      getter name : String
      getter label : String
      getter type : String
      property value : String
      getter help : String?
      getter required : Bool
      getter options : Array(Option)?
      getter mono : Bool
      getter wide : Bool
      getter maxlength : Int32?
      getter placeholder : String?
      property errors : Array(String)?

      def initialize(@name, @label, @type = "text", @value = "", @help = nil, @required = false,
                     options : Array(Option)? = nil, @mono = false, @wide = false, @maxlength = nil, @placeholder = nil)
        @options = options.try { |list| list.map { |option| Option.new(option.value, option.label, option.value == @value) } }
      end

      def id : String
        "pd-f-#{name.gsub(/[^A-Za-z0-9]+/, "-")}"
      end

      def error_id : String
        "#{id}-errors"
      end

      def help_id : String
        "#{id}-help"
      end

      def checked : Bool
        type == "checkbox" && value == "1"
      end

      def text : Bool
        !%w[select checkbox textarea].includes?(type)
      end

      def input_type : String
        case type
        when "number"   then "text"
        when "date"     then "date"
        when "email"    then "email"
        when "password" then "password"
        else                 "text"
        end
      end

      def inputmode : String?
        type == "number" ? "decimal" : nil
      end

      def describedby : String?
        ids = [] of String
        ids << help_id if help
        ids << error_id if errors
        ids.empty? ? nil : ids.join(" ")
      end
    end

    # Groupe de champs (fieldset) ; `legend` nil : sans légende.
    class Group
      include Marten::Template::Object::Auto

      getter legend : String?
      getter fields : Array(Field)

      def initialize(@legend, @fields)
      end
    end

    getter groups : Array(Group)
    getter base_errors : Array(String)?

    def initialize(@groups : Array(Group))
      @base_errors = nil
    end

    def fields : Array(Field)
      @groups.flat_map(&.fields)
    end

    # Range les erreurs d'un résultat du contrat : sous le champ de même nom,
    # ou sous le premier champ dont le nom commence par `champ.`
    # (`address` → `address.line1`), sinon à l'ensemble.
    #
    # `format` : présentation des dates que le cœur passe en ISO dans les
    # paramètres du message (`2026-01-01` → `01/01/2026`, D-UI-017).
    def add_errors(errors : Enumerable(Partiduo::Api::FieldError), format : Format = Format.new(I18n.locale)) : self
      errors.each { |error| add_error(error.field, format.message(error)) }
      self
    end

    def add_error(field_name : String, message : String) : self
      target = fields.find { |field| field.name == field_name } ||
               fields.find(&.name.starts_with?("#{field_name}."))
      if target && field_name != Partiduo::Api::FieldError::BASE
        target.errors = (target.errors || [] of String) << message
      else
        @base_errors = (@base_errors || [] of String) << message
      end
      self
    end

    def invalid : Bool
      !@base_errors.nil? || fields.any?(&.errors)
    end
  end
end
