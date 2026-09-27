# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Retour instantané de la saisie (`ui/entries/_check.html`) : équilibre
  # débit/crédit, totaux d'une facture, lignes telles qu'elles seraient
  # enregistrées, refus du contrat. Tout vient des requêtes de contrôle ;
  # l'interface ne fait que présenter (montants selon la langue et le pays).
  class EntryCheck
    include Marten::Template::Object::Auto

    class Row
      include Marten::Template::Object::Auto

      getter account : String
      getter account_label : String
      getter label : String
      getter debit : String
      getter credit : String
      getter vat : String

      def initialize(@account, @account_label, @label, @debit, @credit, @vat)
      end
    end

    getter total_debit : String = ""
    getter total_credit : String = ""
    getter difference : String = ""
    getter balanced : Bool = false
    getter checked : Bool = false
    getter total_excluding_vat : String? = nil
    getter total_vat : String? = nil
    getter total_including_vat : String? = nil
    getter receipt : String? = nil
    getter rows : Array(Row)? = nil
    property errors : Array(String)? = nil
    property date_hint : String? = nil
    property due_date_hint : String? = nil

    def initialize(@format : Format)
    end

    # `difference` : écart donné par le refus du contrat, sinon débit − crédit.
    def balance(debit : BigDecimal, credit : BigDecimal, difference : BigDecimal? = nil) : Nil
      @checked = true
      @total_debit = @format.amount(debit)
      @total_credit = @format.amount(credit)
      @difference = @format.amount((difference || debit - credit).abs)
      @balanced = difference.nil? && debit == credit && !debit.zero?
    end

    def draft(view : Partiduo::Api::Accounting::EntryDraftView, document : Bool = false) : Nil
      balance(view.total_debit, view.total_credit)
      @receipt = view.receipt.presence
      if document
        @total_excluding_vat = @format.amount(view.total_excluding_vat)
        @total_vat = @format.amount(view.total_vat)
        @total_including_vat = @format.amount(view.total_including_vat)
      end
      @rows = rows_of([view])
    end

    # Extrait : une écriture par ligne, totaux cumulés.
    def drafts(views : Array(Partiduo::Api::Accounting::EntryDraftView)) : Nil
      debit = views.sum(BigDecimal.new(0), &.total_debit)
      credit = views.sum(BigDecimal.new(0), &.total_credit)
      balance(debit, credit)
      @rows = rows_of(views)
    end

    def state : String
      return "" unless @checked
      @balanced ? "ok" : "gap"
    end

    private def rows_of(views : Array(Partiduo::Api::Accounting::EntryDraftView)) : Array(Row)?
      rows = views.flat_map(&.lines).map do |line|
        debit = line.side.debit? ? @format.amount(line.amount) : ""
        credit = line.side.credit? ? @format.amount(line.amount) : ""
        Row.new(line.account_number, line.account_label, line.label, debit, credit, line.vat_rate_code || "")
      end
      rows.empty? ? nil : rows
    end
  end
end
