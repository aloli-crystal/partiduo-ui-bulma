# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Tableau de bord du mode simplifié de la profession libérale (ADR-007 D3,
  # D6) : recettes et dépenses professionnelles de l'année (rubriques de la
  # 2035-A, hors apports, emprunts et prélèvements), encaissé du mois,
  # résultat estimé de la 2035 en cours, factures à encaisser (Facturation
  # active), dépenses par rubrique, dernières lignes, « À traiter » (2035 de
  # l'année écoulée). Tout vient de `Partiduo::Api` (`Liberal`, `Invoicing`).
  class LiberalDashboard
    include Marten::Template::Object::Auto

    alias Liberal = Partiduo::Api::Liberal

    # Rubrique de dépense de l'année : libellé, montant, part (barre).
    class Heading
      include Marten::Template::Object::Auto

      getter label : String
      getter amount : String
      getter width : Int32

      def initialize(@label, @amount, @width)
      end
    end

    getter tiles = [] of Dashboard::Tile
    getter todos = [] of Dashboard::Todo
    getter headings = [] of Heading
    getter lines : Array(Dashboard::Row)? = nil
    getter year : Int32
    getter new_receipt_url : String? = nil
    getter new_expense_url : String? = nil
    getter new_invoice_url : String? = nil

    def initialize(@actor : Partiduo::Api::Actor, @fmt : Format, @active : Set(String), @today : Time = Partiduo::Api::Core.today)
      @year = @today.year
    end

    def build : self
      totals
      latest_lines
      invoicing if @active.includes?("INVOICING") && @actor.can?("invoicing.invoice.read")
      # Tuiles des extensions actives (DECISIONS D-HOOK-001).
      @tiles.concat(Extensions.tiles(@actor, @fmt, @active))
      previous_return
      if @actor.can?(Liberal::WRITE)
        @new_receipt_url = reverse("liberal:receipt_new")
        @new_expense_url = reverse("liberal:expense_new")
      end
      if @active.includes?("INVOICING") && @actor.can?("invoicing.invoice.write")
        @new_invoice_url = reverse("invoicing:invoice_new")
      end
      self
    end

    def listed_tiles : Array(Dashboard::Tile)?
      @tiles.empty? ? nil : @tiles
    end

    def listed_todos : Array(Dashboard::Todo)?
      @todos.empty? ? nil : @todos
    end

    def listed_headings : Array(Heading)?
      @headings.empty? ? nil : @headings
    end

    def add_todo(todo : Dashboard::Todo) : Nil
      @todos << todo
    end

    private def euros(value : BigDecimal, decimals : Int32 = 2) : String
      "#{@fmt.amount(value, decimals)} €"
    end

    private def reverse(name : String, **params) : String
      Marten.routes.reverse(name, **params)
    end

    # Recettes et dépenses professionnelles de l'année (ventilation du
    # contrat), encaissé du mois, résultat estimé de la 2035.
    private def totals : Nil
      by_heading = Liberal.heading_totals(@actor, @year)
      professional = by_heading.reject { |item| Liberal::EXCLUDED_HEADINGS.includes?(item.heading) }
      receipts = professional.select(&.kind.==("receipt")).sum(BigDecimal.new(0), &.amount)
      expenses = professional.select(&.kind.==("expense")).sum(BigDecimal.new(0), &.amount)
      @tiles << Dashboard::Tile.new("LIBERAL", I18n.t("ui.liberal.dashboard.receipts", year: @year.to_s), euros(receipts),
        sub: I18n.t("ui.liberal.dashboard.receipts_sub"), url: reverse("liberal:receipts"))
      first = Time.utc(@today.year, @today.month, 1)
      last = Time.utc(@today.year, @today.month, Time.days_in_month(@today.year, @today.month))
      month = Liberal.journal_totals(@actor, Liberal::JournalQuery.new(from: first, to: last, kind: "receipt")).receipts
      @tiles << Dashboard::Tile.new("LIBERAL", I18n.t("ui.liberal.dashboard.month", month: @fmt.month(@today)), euros(month),
        url: reverse("liberal:receipts"))
      @tiles << Dashboard::Tile.new("LIBERAL", I18n.t("ui.liberal.dashboard.expenses", year: @year.to_s), euros(expenses),
        sub: I18n.t("ui.liberal.dashboard.expenses_sub"), url: reverse("liberal:expenses"))
      view = Liberal.tax_return(@actor, @year)
      result = view.amount("profit") - view.amount("loss")
      @tiles << Dashboard::Tile.new("LIBERAL", I18n.t("ui.liberal.dashboard.result", year: @year.to_s), euros(result, 0),
        sub: I18n.t("ui.liberal.dashboard.result_sub"), url: reverse("liberal:tax_return"))
      spent = professional.select(&.kind.==("expense")).reject(&.amount.zero?).sort_by! { |item| -item.amount }
      top = spent.first?.try(&.amount) || BigDecimal.new(0)
      spent.first(6).each do |item|
        width = top > 0 ? (item.amount * 100 / top).round(0, mode: :ties_away).to_i : 0
        @headings << Heading.new(I18n.t("liberal.headings.#{item.heading}"), euros(item.amount), width)
      end
    end

    private def latest_lines : Nil
      query = Liberal::JournalQuery.new(from: Time.utc(@year, 1, 1), to: Time.utc(@year, 12, 31))
      count = Liberal.journal_totals(@actor, query).count
      latest = Liberal.lines(@actor, query.copy_with(offset: Math.max(count - 5, 0), limit: 5))
      rows = latest.reverse.map do |line|
        amount = line.receipt? ? euros(line.amount) : "−#{euros(line.amount)}"
        Dashboard::Row.new([@fmt.date(line.date), line.party_name.presence || line.label.presence || line.nature_label, amount,
                            line.number], reverse("liberal:line", id: line.id))
      end
      @lines = rows.empty? ? nil : rows
    end

    # 2035 des revenus de l'année écoulée : à préparer tant qu'elle compte
    # des contrôles bloquants (de janvier à juin).
    private def previous_return : Nil
      return if @today.month > 6
      previous = @year - 1
      return if Liberal.journal_totals(@actor, Liberal::JournalQuery.new(from: Time.utc(previous, 1, 1), to: Time.utc(previous, 12, 31))).count.zero?
      view = Liberal.tax_return(@actor, previous)
      errors = view.controls.count(&.error?)
      url = "#{reverse("liberal:tax_return")}?year=#{previous}"
      if errors > 0
        @todos << Dashboard::Todo.new(I18n.t("ui.liberal.dashboard.todo_errors", year: previous.to_s, count: errors), nil, url, "gap")
      else
        @todos << Dashboard::Todo.new(I18n.t("ui.liberal.dashboard.todo_ready", year: previous.to_s), nil, url, "warn")
      end
    end

    # Factures à encaisser (Facturation) et brouillons à valider.
    private def invoicing : Nil
      summary = Partiduo::Api::Invoicing.summary(@actor, @today)
      late = summary.overdue_amount
      @tiles << Dashboard::Tile.new("INVOICING", I18n.t("ui.liberal.dashboard.to_collect"), euros(summary.open_amount),
        alert: late.zero? ? nil : I18n.t("ui.dashboard.tiles.late", amount: @fmt.amount(late)),
        url: "#{reverse("invoicing:documents")}?kind=invoice")
      if summary.drafts > 0
        @todos << Dashboard::Todo.new(I18n.t("ui.dashboard.todo.drafts", count: summary.drafts), nil,
          "#{reverse("invoicing:documents")}?status=draft", "warn")
      end
    rescue Partiduo::Api::AccessDenied
      nil
    end
  end
end
