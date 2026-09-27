# SPDX-License-Identifier: AGPL-3.0-or-later

require "big"

module PartiduoUi
  # Présentation des montants, taux et dates selon la langue de
  # l'utilisateur et le pays de la société (conventions CLDR, DECISIONS
  # D-UI-017). Les montants restent des `BigDecimal` d'un bout à l'autre :
  # aucun passage par `Float`.
  struct Format
    # Séparateurs et motif de date d'une paire langue-pays.
    record Convention, decimal : String, group : String, date : String, percent : String

    NARROW_NBSP = " "

    # Langue seule (pays sans règle propre) puis paires langue-pays.
    CONVENTIONS = {
      "fr"    => Convention.new(",", NARROW_NBSP, "%d/%m/%Y", "#{NARROW_NBSP}%"),
      "fr-BE" => Convention.new(",", NARROW_NBSP, "%d/%m/%Y", "#{NARROW_NBSP}%"),
      "nl"    => Convention.new(",", ".", "%d-%m-%Y", "%"),
      "nl-BE" => Convention.new(",", ".", "%d/%m/%Y", "%"),
      "en"    => Convention.new(".", ",", "%d/%m/%Y", "%"),
      "en-BE" => Convention.new(",", ".", "%d/%m/%Y", "%"),
      "en-FR" => Convention.new(",", NARROW_NBSP, "%d/%m/%Y", "%"),
      "en-US" => Convention.new(".", ",", "%m/%d/%Y", "%"),
    }

    getter locale : String
    getter country : String
    getter convention : Convention

    def initialize(locale : String, country : String = "")
      @locale = locale.split(/[-_]/).first.downcase
      @country = country.upcase
      @convention = CONVENTIONS["#{@locale}-#{@country}"]? || CONVENTIONS[@locale]? || CONVENTIONS["fr"]
    end

    # Montant à `decimals` décimales (arrondi au demi supérieur), groupé :
    # `1 234,50` (fr), `1.234,50` (nl-BE), `1,234.50` (en).
    def amount(value : BigDecimal?, decimals : Int32 = 2, group : Bool = true) : String
      return "" if value.nil?
      rounded = value.round(decimals, mode: :ties_away)
      digits(rounded, decimals, group)
    end

    # Nombre sans zéros inutiles (`5,5`, `20`) : taux, quantités.
    def number(value : BigDecimal?, max_decimals : Int32 = 4) : String
      return "" if value.nil?
      text = amount(value, max_decimals, group: true)
      return text unless text.includes?(@convention.decimal)
      text.rstrip('0').rchop(@convention.decimal)
    end

    # Taux en pourcentage (`20 %`, `5,5 %`).
    def percent(value : BigDecimal?) : String
      return "" if value.nil?
      "#{number(value)}#{@convention.percent}"
    end

    def date(value : Time?) : String
      return "" if value.nil?
      value.to_s(@convention.date)
    end

    # Nom du mois (`septembre 2026`) : période mensuelle.
    def month(value : Time) : String
      "#{I18n.t("ui.months.m#{value.month}")} #{value.year}"
    end

    # Libellé d'une période : mois entier, jour unique ou bornes.
    def period(starts_on : Time, ends_on : Time) : String
      return date(starts_on) if starts_on == ends_on
      last_day = Time.days_in_month(starts_on.year, starts_on.month)
      if starts_on.day == 1 && ends_on.year == starts_on.year && ends_on.month == starts_on.month && ends_on.day == last_day
        month(starts_on)
      else
        "#{date(starts_on)} – #{date(ends_on)}"
      end
    end

    # Montant pour un export CSV : séparateur décimal de la langue, sans
    # séparateur de milliers (relu tel quel par un tableur).
    def csv_amount(value : BigDecimal?, decimals : Int32 = 2) : String
      amount(value, decimals, group: false)
    end

    # Séparateur de champs CSV : le point-virgule quand la virgule est le
    # séparateur décimal (tableurs européens).
    def csv_separator : Char
      @convention.decimal == "," ? ';' : ','
    end

    # Lecture d'un nombre saisi (`1 234,56`, `1.234,56`, `1234.56`) ; `nil` si
    # la saisie n'est pas un nombre. Le dernier séparateur décimal rencontré
    # l'emporte, les autres sont des séparateurs de milliers.
    def self.parse_decimal(text : String) : BigDecimal?
      cleaned = text.strip.gsub(/[\s  ']/, "")
      return if cleaned.empty?
      negative = cleaned.starts_with?('-')
      cleaned = cleaned.lchop('-').lchop('+')
      last = {cleaned.rindex(','), cleaned.rindex('.')}.to_a.compact.max?
      normalized = if last
                     whole = cleaned[0...last].delete(",.")
                     fraction = cleaned[(last + 1)..]
                     fraction.empty? ? whole : "#{whole}.#{fraction}"
                   else
                     cleaned
                   end
      return unless normalized.matches?(/\A\d+(\.\d+)?\z/) || normalized.matches?(/\A\.\d+\z/)
      value = BigDecimal.new(normalized)
      negative ? -value : value
    rescue ArgumentError | InvalidBigDecimalException
      nil
    end

    # Date saisie : `AAAA-MM-JJ` (champ date du navigateur) ou le motif de la
    # langue (`27/09/2026`). Minuit UTC (convention C1 du cœur).
    def parse_date(text : String) : Time?
      value = text.strip
      return if value.empty?
      ["%Y-%m-%d", @convention.date].each do |pattern|
        return Time.parse(value, pattern, Time::Location::UTC)
      rescue Time::Format::Error | ArgumentError
        next
      end
      nil
    end

    private def digits(value : BigDecimal, decimals : Int32, group : Bool) : String
      negative = value < 0
      text = value.abs.to_s
      whole, _, fraction = text.partition('.')
      fraction = (fraction + "0" * decimals)[0, decimals]
      whole = grouped(whole) if group
      result = decimals > 0 ? "#{whole}#{@convention.decimal}#{fraction}" : whole
      negative && (whole != "0" || fraction.each_char.any? { |char| char != '0' }) ? "-#{result}" : result
    end

    private def grouped(whole : String) : String
      return whole if whole.size <= 3
      head = whole.size % 3
      parts = [] of String
      parts << whole[0, head] if head > 0
      (head...whole.size).step(3) { |index| parts << whole[index, 3] }
      parts.join(@convention.group)
    end
  end
end
