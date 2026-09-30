# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Édition d'un devis, d'une commande, d'un bon de livraison, d'une facture,
  # d'une facture d'acompte ou d'un avoir en brouillon (maquette « Édition
  # d'un devis ou d'une facture ») : en-tête et lignes relus depuis les champs
  # envoyés, rendus par `ui/invoicing/edit.html`. Totaux, TVA et refus
  # viennent de `Api::Invoicing.check_document` ; les mentions obligatoires,
  # de l'émission.
  #
  # Une ligne : article (code de fiche, complété), désignation, quantité,
  # unité, prix unitaire HT, remise en %, taux de TVA. Nature déduite :
  # article s'il est donné, sinon désignation chiffrée (`free`) si un prix ou
  # une quantité est saisi, sinon note (`note`) ; ligne de titre ou de
  # sous-total si la mise en forme le demande (`layout`, ADR-006 D5,
  # D-UI-055). Champs `line-<n>-<champ>`.
  class DocumentForm
    include Marten::Template::Object::Auto

    LINE_FIELD = /\Aline-(\d+)-([a-z_]+)\z/

    class Line
      include Marten::Template::Object::Auto

      getter index : Int32
      property item : String
      property description : String
      property quantity : String
      property unit : String
      property unit_price : String
      property discount : String
      property vat_rate_id : String
      # Mise en forme : vide (ligne chiffrée ou note), `title`, `subtotal`.
      property layout : String = ""
      # Bon de livraison dont la ligne d'une facture est issue (identifiant,
      # champ caché `line-<n>-delivery_note`, D-INV2-002) ; vide sinon.
      property delivery_note : String = ""
      property total : String = ""
      property vat_options : Array(Form::Option)?
      property errors : Array(String)?

      def initialize(@index, @item = "", @description = "", @quantity = "", @unit = "", @unit_price = "", @discount = "",
                     @vat_rate_id = "")
      end

      LAYOUTS = %w[title subtotal]

      def blank : Bool
        layout != "subtotal" && [item, description, quantity, unit_price, discount].all?(&.strip.empty?)
      end

      def title : Bool
        layout == "title"
      end

      def subtotal : Bool
        layout == "subtotal"
      end

      def number : Int32
        index + 1
      end

      def error_id : String
        "pd-dl#{index}-errors"
      end

      def add_error(message : String) : Nil
        @errors = (@errors || [] of String) << message
      end
    end

    # `issue_channel` : vide = proposition du cœur selon le client ;
    # `b2c` : vide (selon le client), `1`, `0` (ADR-004 D9).
    # `payment_terms` : vide (délai des paramètres), `on_receipt`,
    # `net:<jours>`, `end_of_month:<jours>` ; `delivery` : vide (adresse de
    # livraison par défaut de la fiche), `none`, `card:<rang>`, `other`
    # (champs `delivery_*`). DECISIONS D-R5-004.
    HEADER = %w[customer issue_date delivery_date due_date validity_date operation_category buyer_reference order_reference
      notes global_discount issue_channel b2c payment_terms delivery delivery_line1 delivery_postcode delivery_city
      delivery_country]

    getter kind : String
    getter lines : Array(Line)
    {% for name in HEADER %}
      property {{ name.id }} : String = ""
    {% end %}
    property category_options : Array(Form::Option)? = nil
    property channel_options : Array(Form::Option)? = nil
    property b2c_options : Array(Form::Option)? = nil
    property terms_options : Array(Form::Option)? = nil
    property delivery_options : Array(Form::Option)? = nil
    # Canal proposé pour le client saisi (« Proposé : … »), `nil` sans client.
    property channel_hint : String? = nil
    property customer_name : String = ""
    getter base_errors : Array(String)? = nil
    @field_errors = {} of String => Array(String)

    def initialize(@kind : String, @lines : Array(Line) = [] of Line)
    end

    def self.blank(kind : String, count : Int32 = 3) : self
      new(kind, (0...count).map { |index| Line.new(index) })
    end

    def self.read(kind : String, values : Hash(String, String)) : self
      form = new(kind)
      {% for name in HEADER %}
        form.{{ name.id }} = values[{{ name }}]?.to_s.strip
      {% end %}
      indices = values.keys.compact_map { |name| name.match(LINE_FIELD).try(&.[1].to_i) }.uniq!.sort!
      indices.each do |index|
        value = ->(name : String) { values["line-#{index}-#{name}"]?.to_s.strip }
        line = Line.new(index, value.call("item"), value.call("description"), value.call("quantity"), value.call("unit"),
          value.call("unit_price"), value.call("discount"), value.call("vat_rate_id"))
        layout = value.call("layout")
        line.layout = Line::LAYOUTS.includes?(layout) ? layout : ""
        line.delivery_note = value.call("delivery_note")
        form.lines << line
      end
      form
    end

    def quote : Bool
      kind == "quote"
    end

    # Conditions de paiement : sans objet pour un avoir ou un bon de livraison.
    def payable : Bool
      !kind.in?("credit_note", "delivery_note")
    end

    # Champs de l'autre adresse de livraison ouverts (choix « autre »).
    def other_delivery : Bool
      delivery == "other"
    end

    def fiscal : Bool
      Partiduo::Api::Invoicing::FISCAL_KINDS.includes?(kind)
    end

    def each_row(& : Line ->) : Nil
      @lines.each { |line| yield line }
    end

    def filled_lines : Array(Line)
      lines.reject(&.blank)
    end

    def next_index : Int32
      (lines.max_of?(&.index) || -1) + 1
    end

    def add_line : Line
      line = Line.new(next_index)
      lines << line
      line
    end

    def remove_line(index : Int32) : Nil
      lines.reject! { |line| line.index == index }
      add_line if lines.empty?
    end

    def renumber! : self
      @lines = lines.map_with_index do |line, position|
        Line.new(position, line.item, line.description, line.quantity, line.unit, line.unit_price, line.discount, line.vat_rate_id)
          .tap(&.layout=(line.layout))
          .tap(&.delivery_note=(line.delivery_note))
      end
      self
    end

    FIELD_MAP = {"customer_card_id" => "customer", "payment_terms_days" => "payment_terms"}

    def add_error(field : String, message : String) : Nil
      if match = field.match(/\Alines\[(\d+)\]/)
        if line = filled_lines[match[1].to_i]?
          return line.add_error(message)
        end
      end
      name = FIELD_MAP[field]? || field
      name = "global_discount" if name.starts_with?("global_discount")
      if HEADER.includes?(name)
        (@field_errors[name] ||= [] of String) << message
      else
        @base_errors = (@base_errors || [] of String) << message
      end
    end

    def invalid : Bool
      !@base_errors.nil? || !@field_errors.empty? || lines.any?(&.errors)
    end

    {% for name in HEADER %}
      def {{ name.id }}_errors : Array(String)?
        @field_errors[{{ name }}]?
      end
    {% end %}
  end
end
