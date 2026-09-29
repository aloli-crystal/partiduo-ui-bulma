# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Tableau de bord du mode simplifié (ADR-007 D3) : chiffre d'affaires
  # encaissé de l'année et du mois, dépensé de l'année, factures à encaisser
  # (Facturation active), prochaine échéance URSSAF et montant estimé,
  # seuils de l'année (jauges), dernières recettes, « À traiter » du module.
  # Tout vient de `Partiduo::Api` (`Micro`, `Invoicing`).
  class MicroDashboard
    include Marten::Template::Object::Auto

    alias Micro = Partiduo::Api::Micro

    # Jauge d'un seuil : part atteinte (bornée à 100 pour l'affichage),
    # textes et ton (`ok`, `warn`, `gap`).
    class Gauge
      include Marten::Template::Object::Auto

      getter label : String
      getter detail : String
      getter status : String
      getter percent : String
      getter width : Int32
      getter tone : String

      def initialize(@label, @detail, @status, @percent, @width, @tone)
      end
    end

    # Échéance URSSAF à venir.
    class Deadline
      include Marten::Template::Object::Auto

      getter period : String
      getter due_on : String
      getter turnover : String
      getter total : String
      getter status : String

      def initialize(@period, @due_on, @turnover, @total, @status)
      end
    end

    getter tiles = [] of Dashboard::Tile
    getter todos = [] of Dashboard::Todo
    getter gauges = [] of Gauge
    getter receipts : Array(Dashboard::Row)? = nil
    getter deadline : Deadline? = nil
    getter year : Int32
    getter new_receipt_url : String? = nil
    getter new_purchase_url : String? = nil
    getter new_invoice_url : String? = nil

    def initialize(@actor : Partiduo::Api::Actor, @fmt : Format, @active : Set(String), @today : Time = Partiduo::Api::Core.today)
      @year = @today.year
    end

    def build : self
      turnover
      deadline_tile
      thresholds
      latest_receipts
      invoicing if @active.includes?("INVOICING") && @actor.can?("invoicing.invoice.read")
      # Tuiles des extensions actives (DECISIONS D-HOOK-001).
      @tiles.concat(Extensions.tiles(@actor, @fmt, @active))
      Micro.todo(@actor, @today).each do |item|
        @todos << Dashboard::Todo.new(MicroText.todo(item, @fmt), nil,
          reverse(item.kind == "declaration" ? "micro:urssaf" : "micro:thresholds"), item.tone)
      end
      if @actor.can?(Micro::WRITE)
        @new_receipt_url = reverse("micro:receipt_new")
        @new_purchase_url = reverse("micro:purchase_new")
      end
      if @active.includes?("INVOICING") && @actor.can?("invoicing.invoice.write")
        @new_invoice_url = reverse("micro:invoice_new")
      end
      self
    end

    def listed_tiles : Array(Dashboard::Tile)?
      @tiles.empty? ? nil : @tiles
    end

    def listed_todos : Array(Dashboard::Todo)?
      @todos.empty? ? nil : @todos
    end

    def listed_gauges : Array(Gauge)?
      @gauges.empty? ? nil : @gauges
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

    private def year_query : Micro::RegisterQuery
      Micro::RegisterQuery.new(from: Time.utc(@year, 1, 1), to: Time.utc(@year, 12, 31))
    end

    private def month_query : Micro::RegisterQuery
      first = Time.utc(@today.year, @today.month, 1)
      Micro::RegisterQuery.new(from: first, to: Time.utc(@today.year, @today.month, Time.days_in_month(@today.year, @today.month)))
    end

    # Chiffre d'affaires encaissé (hors TVA) de l'année et du mois ;
    # dépensé hors TVA déductible de l'année (agrégats du contrat).
    private def turnover : Nil
      year_total = Micro.receipts_total(@actor, year_query).net_amount
      @tiles << Dashboard::Tile.new("MICRO", I18n.t("ui.micro.dashboard.turnover", year: @year.to_s), euros(year_total),
        sub: I18n.t("ui.micro.dashboard.turnover_sub"), url: reverse("micro:receipts"))
      @tiles << Dashboard::Tile.new("MICRO", I18n.t("ui.micro.dashboard.month", month: @fmt.month(@today)),
        euros(Micro.receipts_total(@actor, month_query).net_amount), url: reverse("micro:receipts"))
      spent = Micro.purchases_total(@actor, year_query).net_amount
      @tiles << Dashboard::Tile.new("MICRO", I18n.t("ui.micro.dashboard.spent", year: @year.to_s), euros(spent),
        url: reverse("micro:purchases"))
    end

    # Prochaine échéance : déclaration en retard, due, sinon la période en
    # cours (l'année précédente comprise, sa dernière échéance tombant en
    # janvier).
    private def deadline_tile : Nil
      item = MicroText.upcoming(@actor, @today)
      return unless item
      status = I18n.t("micro.declaration_statuses.#{item.status}")
      @deadline = Deadline.new(@fmt.period(item.starts_on, item.ends_on), @fmt.date(item.due_on), euros(item.turnover),
        euros(item.total), status)
      @tiles << Dashboard::Tile.new("MICRO", I18n.t("ui.micro.dashboard.deadline", date: @fmt.date(item.due_on)), euros(item.total),
        sub: I18n.t("ui.micro.dashboard.deadline_sub", period: @fmt.period(item.starts_on, item.ends_on), turnover: euros(item.turnover)),
        alert: item.status == "late" ? status : nil, url: reverse("micro:urssaf"))
    end

    private def thresholds : Nil
      view = Micro.thresholds(@actor, @year)
      view.thresholds.each do |item|
        next if item.status.in?("not_applicable", "unknown")
        limit = item.limit || next
        ratio = item.ratio || BigDecimal.new(0)
        width = ratio > 100 ? 100 : ratio.round(0, mode: :ties_away).to_i
        tone = case item.status
               when "approaching" then "warn"
               when "ok"          then "ok"
               else                    "gap"
               end
        label = I18n.t("ui.micro.dashboard.gauge_#{item.kind}", area: I18n.t("micro.scopes.#{item.scope}"))
        detail = I18n.t("ui.micro.dashboard.gauge_detail", turnover: euros(item.turnover, 0), limit: euros(limit, 0))
        @gauges << Gauge.new(label, detail, I18n.t("micro.threshold_statuses.#{item.status}"), @fmt.percent(ratio), width, tone)
      end
    end

    private def latest_receipts : Nil
      count = Micro.receipts_total(@actor, year_query).count
      latest = Micro.receipts(@actor, year_query.copy_with(offset: Math.max(count - 5, 0), limit: 5))
      rows = latest.reverse.map do |line|
        Dashboard::Row.new([@fmt.date(line.date), line.party_name.presence || line.nature_label, euros(line.amount), line.number],
          reverse("micro:receipt", id: line.id))
      end
      @receipts = rows.empty? ? nil : rows
    end

    # Factures à encaisser (Facturation) et brouillons à valider.
    private def invoicing : Nil
      summary = Partiduo::Api::Invoicing.summary(@actor, @today)
      late = summary.overdue_amount
      @tiles << Dashboard::Tile.new("INVOICING", I18n.t("ui.micro.dashboard.to_collect"), euros(summary.open_amount),
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
