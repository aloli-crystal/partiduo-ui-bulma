# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Formulaire de saisie d'une écriture (lot 2, ADR-005 D5) : en-tête
  # (journal, date, pièce, libellé, tiers, échéance) et lignes, relu depuis
  # les champs envoyés et rendu par `ui/entries/form.html`. Aucune règle
  # comptable ici : l'équilibre, la TVA et les refus viennent des requêtes de
  # contrôle du contrat (`check_entry`, `check_document`, `check_financial`).
  #
  # Quatre formes, comme les menus du manifeste de la Comptabilité :
  #
  # * `misc` : opérations diverses — compte ou fiche, libellé, débit, crédit ;
  # * `purchase`, `sale` : facture d'achat ou de vente — article ou compte,
  #   libellé, montant hors taxe, taux de TVA ; tiers et échéance ;
  # * `financial` : extrait — contrepartie (fiche ou compte), libellé, entrée,
  #   sortie ; une écriture par ligne.
  #
  # Champs des lignes : `line-<n>-<champ>` ; une ligne entièrement vide est
  # ignorée (lignes de réserve du formulaire).
  class EntryForm
    include Marten::Template::Object::Auto

    KINDS      = %w[purchase sale financial misc]
    LINE_FIELD = /\Aline-(\d+)-([a-z_]+)\z/

    class Line
      include Marten::Template::Object::Auto

      getter index : Int32
      getter kind : String
      property account : String
      property label : String
      property debit : String
      property credit : String
      property amount : String
      property vat_rate : String
      property vat_options : Array(Form::Option)?
      property errors : Array(String)?

      def initialize(@index, @kind, @account = "", @label = "", @debit = "", @credit = "", @amount = "", @vat_rate = "")
      end

      def blank : Bool
        [account, label, debit, credit, amount].all?(&.strip.empty?)
      end

      def document : Bool
        kind.in?("purchase", "sale")
      end

      def financial : Bool
        kind == "financial"
      end

      def misc : Bool
        kind == "misc"
      end

      # Liste de complétion du champ compte (`ui/entries/_datalists.html`).
      def completion : String
        case kind
        when "purchase", "sale" then "items"
        when "financial"        then "parties"
        else                         "entry"
        end
      end

      def error_id : String
        "pd-l#{index}-errors"
      end

      # Numéro affiché (libellés des champs pour les lecteurs d'écran).
      def number : Int32
        index + 1
      end

      def add_error(message : String) : Nil
        @errors = (@errors || [] of String) << message
      end
    end

    getter kind : String
    getter lines : Array(Line)
    property ledger_id : String = ""
    property date : String = ""
    property receipt : String = ""
    property label : String = ""
    property third_party : String = ""
    property due_date : String = ""
    property ledger_options : Array(Form::Option)? = nil
    property receipt_placeholder : String = ""
    # Date comprise (saisie abrégée), affichée à côté du champ.
    property date_hint : String? = nil
    property due_date_hint : String? = nil
    getter base_errors : Array(String)? = nil
    @field_errors = {} of String => Array(String)

    def initialize(@kind : String, @lines : Array(Line) = [] of Line)
    end

    # Formulaire vierge : `count` lignes de réserve.
    def self.blank(kind : String, count : Int32 = 2) : self
      new(kind, (0...count).map { |index| Line.new(index, kind) })
    end

    # Formulaire relu depuis les champs envoyés (`name => valeur`).
    def self.read(kind : String, values : Hash(String, String)) : self
      form = new(kind)
      form.ledger_id = values["ledger_id"]?.to_s.strip
      form.date = values["date"]?.to_s.strip
      form.receipt = values["receipt"]?.to_s.strip
      form.label = values["label"]?.to_s.strip
      form.third_party = values["third_party"]?.to_s.strip
      form.due_date = values["due_date"]?.to_s.strip
      indices = values.keys.compact_map { |name| name.match(LINE_FIELD).try(&.[1].to_i) }.uniq!.sort!
      indices.each do |index|
        value = ->(name : String) { values["line-#{index}-#{name}"]?.to_s.strip }
        form.lines << Line.new(index, kind, value.call("account"), value.call("label"), value.call("debit"),
          value.call("credit"), value.call("amount"), value.call("vat_rate"))
      end
      form
    end

    def document : Bool
      kind.in?("purchase", "sale")
    end

    def financial : Bool
      kind == "financial"
    end

    def misc : Bool
      kind == "misc"
    end

    def each_row(& : Line ->) : Nil
      @lines.each { |line| yield line }
    end

    def sale : Bool
      kind == "sale"
    end

    # Lignes remplies, dans l'ordre : l'index de la ligne `n` du contrat
    # (`lines[n]`) est son rang dans cette liste.
    def filled_lines : Array(Line)
      lines.reject(&.blank)
    end

    # Index du prochain champ de ligne (ajout d'une ligne).
    def next_index : Int32
      (lines.max_of?(&.index) || -1) + 1
    end

    def add_line : Line
      line = Line.new(next_index, kind)
      lines << line
      line
    end

    def remove_line(index : Int32) : Nil
      lines.reject! { |line| line.index == index }
      add_line if lines.empty?
    end

    # Rang 0 à n : mêmes lignes de réserve partout (`line-0-…`).
    def renumber! : self
      @lines = lines.map_with_index do |line, position|
        copy = Line.new(position, kind, line.account, line.label, line.debit, line.credit, line.amount, line.vat_rate)
        copy.vat_options = line.vat_options
        copy.errors = line.errors
        copy
      end
      self
    end

    def add_error(field : String, message : String) : Nil
      if match = field.match(/\Alines\[(\d+)\]/)
        if line = filled_lines[match[1].to_i]?
          return line.add_error(message)
        end
      end
      if field.in?("ledger_id", "date", "receipt", "label", "third_party", "due_date")
        (@field_errors[field] ||= [] of String) << message
      else
        @base_errors = (@base_errors || [] of String) << message
      end
    end

    def invalid : Bool
      !@base_errors.nil? || !@field_errors.empty? || lines.any?(&.errors)
    end

    {% for name in %w[ledger_id date receipt label third_party due_date] %}
      def {{ name.id }}_errors : Array(String)?
        @field_errors[{{ name }}]?
      end
    {% end %}
  end
end
