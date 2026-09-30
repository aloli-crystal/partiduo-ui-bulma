# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Aide à la déclaration URSSAF (ADR-007 D1, D3) : prochaine déclaration et
  # montants à reporter sur le site de l'URSSAF (chiffre d'affaires encaissé
  # par catégorie, en euros entiers), cotisations estimées, échéances de
  # l'année ; déclaration notée « faite » (pas de télétransmission).
  class UrssafHandler < MicroScreen
    # Période présentée dans l'écran.
    class Period
      include Marten::Template::Object::Auto

      # Montant par catégorie : à reporter (euros entiers), encaissé exact,
      # cotisation estimée.
      class Line
        include Marten::Template::Object::Auto

        getter label : String
        getter report : String
        getter exact : String
        getter contribution : String
        getter rates : String

        def initialize(@label, @report, @exact, @contribution, @rates)
        end
      end

      getter label : String
      getter starts_on : String
      getter due_on : String
      getter status : String
      getter status_label : String
      getter turnover : String
      getter total : String
      getter lines : Array(Line)
      getter missing : String?
      getter declared : String?
      getter can_declare : Bool # ameba:disable Naming/QueryBoolMethods

      def initialize(@label, @starts_on, @due_on, @status, @status_label, @turnover, @total, @lines, @missing,
                     @declared, @can_declare)
      end

      def late : Bool
        status == "late"
      end
    end

    def get
      year = year_param
      declarations = Micro.declarations(current.actor, year, today)
      upcoming = MicroText.upcoming(current.actor, today)
      settings = Micro.settings(current.actor)
      table = Table.new(I18n.t("ui.micro.urssaf.periods"), columns, declarations.map { |item| row(item) },
        reverse("micro:urssaf"), {"year" => year.to_s}, empty_message: I18n.t("ui.micro.urssaf.empty"))
      table.exportable = false
      context["title"] = I18n.t("ui.micro.urssaf.title")
      context["crumbs"] = micro_crumbs
      context["upcoming"] = upcoming.try { |item| period(item) }
      context["table"] = table
      context["tabs"] = year_tabs(reverse("micro:urssaf"), year)
      context["year"] = year.to_s
      context["periodicity"] = I18n.t("micro.periodicities.#{settings.periodicity}")
      context["flat_tax"] = settings.flat_tax
      context["declare_url"] = reverse("micro:urssaf_declare")
      context["today"] = today.to_s("%Y-%m-%d")
      context["tax_return_url"] = reverse("micro:tax_return")
      context["thresholds_url"] = reverse("micro:thresholds")
      page("ui/micro/urssaf.html")
    end

    private def period(item : Micro::DeclarationView) : Period
      lines = item.contributions.map do |contribution|
        rates = [contribution.social_rate, contribution.cfp_rate, contribution.flat_tax_rate].compact.map { |rate| fmt.percent(rate) }.join(" + ")
        Period::Line.new(category_label(contribution.category), euros(contribution.turnover.round(0, mode: :ties_away), 0),
          euros(contribution.turnover), euros(contribution.total), rates)
      end
      missing = item.missing_rates.empty? ? nil : I18n.t("ui.micro.urssaf.missing_rates", codes: item.missing_rates.join(", "))
      declared = item.declared_on.try { |day| I18n.t("ui.micro.urssaf.declared_on", date: fmt.date(day), reference: item.reference) }
      Period.new(fmt.period(item.starts_on, item.ends_on), item.starts_on.to_s("%Y-%m-%d"), fmt.date(item.due_on), item.status,
        I18n.t("micro.declaration_statuses.#{item.status}"), euros(item.turnover), euros(item.total), lines, missing, declared,
        item.status.in?("due", "late") && can?(WRITE))
    end

    private def columns : Array(Table::Column)
      [
        Table::Column.new("period", I18n.t("ui.micro.urssaf.period"), sortable: false),
        Table::Column.new("due", I18n.t("ui.micro.urssaf.due_on"), "mono", sortable: false),
        Table::Column.new("turnover", I18n.t("ui.micro.urssaf.turnover"), "amount", sortable: false),
        Table::Column.new("total", I18n.t("ui.micro.urssaf.contributions"), "amount", secondary: true, sortable: false),
        Table::Column.new("status", I18n.t("ui.micro.urssaf.status"), sortable: false),
      ]
    end

    private def row(item : Micro::DeclarationView) : Table::Row
      Table::Row.new([
        Table::Cell.new(fmt.period(item.starts_on, item.ends_on)),
        Table::Cell.new(fmt.date(item.due_on)),
        Table::Cell.new(euros(item.turnover)),
        Table::Cell.new(euros(item.total)),
        Table::Cell.new(I18n.t("micro.declaration_statuses.#{item.status}")),
      ], item.status == "late" ? "pd-row-warning" : "")
    end
  end

  # Déclaration faite sur le site de l'URSSAF : notée pour la période qui
  # commence le `starts_on`, à la date du jour, avec sa référence.
  class UrssafDeclareHandler < MicroScreen
    def post
      require!(MODULE, WRITE)
      starts_on = fmt.parse_date(field("starts_on"))
      if starts_on.nil?
        flash["danger"] = I18n.t("ui.forms.invalid_date")
        return go(reverse("micro:urssaf"))
      end
      result = Micro.mark_declared(current.actor, Micro::DeclarationInput.new(starts_on, today, field("reference")))
      if declared = result.value?
        flash["success"] = I18n.t("ui.micro.urssaf.declared", period: fmt.period(declared.starts_on, declared.ends_on))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go("#{reverse("micro:urssaf")}?year=#{starts_on.year}")
    end
  end

  # Montants de la 2042-C-PRO (ADR-007 D1) : chiffre d'affaires annuel par
  # catégorie, en euros entiers, avec la case du millésime.
  class TaxReturnHandler < MicroScreen
    def get
      year = year_param
      view = Micro.tax_return(current.actor, year)
      items = view.boxes.map do |box|
        label = box.box.empty? ? category_label(box.category) : I18n.t("ui.micro.tax_return.box", box: box.box, category: category_label(box.category))
        Screen::Item.new(label, euros(box.amount, 0), mono: true)
      end
      total = view.boxes.sum(BigDecimal.new(0), &.amount)
      items << Screen::Item.new(I18n.t("ui.micro.tax_return.total"), euros(total, 0), mono: true)
      note = I18n.t(view.flat_tax ? "ui.micro.tax_return.flat_tax" : "ui.micro.tax_return.no_flat_tax")
      sections = [Screen::Section.new(I18n.t("ui.micro.tax_return.amounts", year: year.to_s), items, note: note)]
      actions = ((today.year - 2)...today.year).map { |value| link_action_text(value.to_s, "#{reverse("micro:tax_return")}?year=#{value}") }
      detail_page(I18n.t("ui.micro.tax_return.title", year: year.to_s),
        micro_crumbs << Screen::Crumb.new(I18n.t("ui.micro.urssaf.title"), reverse("micro:urssaf")), sections, actions,
        intro: I18n.t("ui.micro.tax_return.intro"))
    end

    private def link_action_text(label : String, url : String) : Screen::Action
      Screen::Action.new(label, url, "get", "small")
    end
  end

  # Seuils de l'année (ADR-007 D1) : franchise en base de TVA et régime
  # micro, chiffre d'affaires encaissé comparé, alertes.
  class ThresholdsHandler < MicroScreen
    def get
      year = year_param
      view = Micro.thresholds(current.actor, year)
      sections = %w[vat micro].map do |kind|
        items = view.thresholds.select(&.kind.==(kind)).map do |item|
          Screen::Item.new(I18n.t("micro.scopes.#{item.scope}"), describe(item))
        end
        Screen::Section.new(I18n.t("ui.micro.thresholds.#{kind}"), items, note: I18n.t("ui.micro.thresholds.#{kind}_note"))
      end
      alerts = view.alerts.map { |alert| MicroText.message(alert.key, alert.params, fmt) }
      totals = [
        Screen::Item.new(I18n.t("ui.micro.thresholds.goods"), euros(view.goods_turnover)),
        Screen::Item.new(I18n.t("ui.micro.thresholds.services"), euros(view.services_turnover)),
        Screen::Item.new(I18n.t("ui.micro.thresholds.total"), euros(view.total_turnover)),
      ]
      sections.unshift(Screen::Section.new(I18n.t("ui.micro.thresholds.turnover", year: year.to_s), totals,
        note: alerts.empty? ? nil : alerts.join(" · ")))
      detail_page(I18n.t("ui.micro.thresholds.title", year: year.to_s),
        micro_crumbs << Screen::Crumb.new(I18n.t("ui.micro.urssaf.title"), reverse("micro:urssaf")), sections,
        intro: I18n.t("ui.micro.thresholds.intro"))
    end

    private def describe(item : Micro::ThresholdView) : String
      status = I18n.t("micro.threshold_statuses.#{item.status}")
      limit = item.limit
      return "#{euros(item.turnover)} · #{status}" if limit.nil?
      ratio = item.ratio.try { |value| " (#{fmt.percent(value)})" } || ""
      I18n.t("ui.micro.thresholds.of", turnover: euros(item.turnover), limit: euros(limit, 0), ratio: ratio, status: status)
    end
  end

  # Paramètres de la micro-entreprise : périodicité des déclarations,
  # versement libératoire, début d'activité, nature par défaut des recettes
  # issues de la Facturation ; liens vers les paramètres du dossier.
  class MicroSettingsHandler < MicroScreen
    def get
      require!(MODULE, SETTINGS)
      settings = Micro.settings(current.actor)
      show(form({
        "periodicity"         => settings.periodicity,
        "flat_tax"            => settings.flat_tax ? "1" : "",
        "activity_started_on" => settings.activity_started_on.try(&.to_s("%Y-%m-%d")) || "",
        "default_nature_id"   => settings.default_nature_id.try(&.to_s) || "",
      }))
    end

    def post
      require!(MODULE, SETTINGS)
      values = {"periodicity" => field("periodicity"), "flat_tax" => checkbox("flat_tax") ? "1" : "",
                "activity_started_on" => field("activity_started_on"), "default_nature_id" => field("default_nature_id")}
      shown = form(values)
      started = values["activity_started_on"].empty? ? nil : fmt.parse_date(values["activity_started_on"])
      shown.add_error("activity_started_on", I18n.t("ui.forms.invalid_date")) if started.nil? && !values["activity_started_on"].empty?
      return show(shown) if shown.invalid
      input = Micro::SettingsInput.new(periodicity: values["periodicity"], flat_tax: values["flat_tax"] == "1",
        activity_started_on: started, default_nature_id: values["default_nature_id"].to_i64?)
      result = Micro.update_settings(current.actor, input)
      if result.success?
        flash["success"] = I18n.t("ui.micro.settings.saved")
        return go(reverse("micro:settings"))
      end
      show(shown.add_errors(result.errors, fmt))
    end

    private def form(values : Hash(String, String)) : Form
      periodicities = Micro::PERIODICITIES.map { |code| option(code, I18n.t("micro.periodicities.#{code}")) }
      natures = [option("", I18n.t("ui.micro.settings.no_nature"))] +
                Micro.natures(current.actor, "receipt", enabled_only: true).map { |item| option(item.id.to_s, item.label) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("periodicity", I18n.t("ui.micro.settings.periodicity"), "select", values["periodicity"], required: true,
          options: periodicities),
        Form::Field.new("flat_tax", I18n.t("ui.micro.settings.flat_tax"), "checkbox", values["flat_tax"],
          help: I18n.t("ui.micro.settings.flat_tax_help")),
        Form::Field.new("activity_started_on", I18n.t("ui.micro.settings.activity_started_on"), "date", values["activity_started_on"],
          help: I18n.t("ui.micro.settings.activity_started_on_help")),
        Form::Field.new("default_nature_id", I18n.t("ui.micro.settings.default_nature"), "select", values["default_nature_id"],
          options: natures, help: I18n.t("ui.micro.settings.default_nature_help")),
      ])])
    end

    private def show(form : Form) : Marten::HTTP::Response
      settings = Micro.settings(current.actor)
      actions = [
        link_action("ui.micro.natures.title", reverse("micro:natures")),
        link_action("ui.micro.parameters.title", reverse("micro:parameters")),
        link_action("ui.micro.items.title", reverse("micro:items")),
      ]
      actions << link_action("ui.micro.switch.vat.title", reverse("micro:switch_vat")) if settings.vat_liable_since.nil?
      actions << link_action("ui.micro.switch.real.title", reverse("micro:switch_real")) if settings.real_regime_since.nil?
      if module_active?("ACCOUNTING")
        actions << post_action("ui.micro.republish.action", reverse("micro:republish"), "ui.micro.republish.confirm")
        actions << link_action("ui.micro.accounts.title", reverse("accounting:micro_accounts")) if can?("accounting.account.read")
      end
      {"core:company" => {"core.settings.manage", "core.menu.core_company"},
       "core:users"   => {"core.users.manage", "core.menu.core_users"},
       "core:modules" => {"core.modules.manage", "core.menu.core_modules"},
       "cards:index"  => {"cards.card.read", "cards.menu.cards_list"}}.each do |route, (permission, label)|
        actions << link_action(label, reverse(route)) if can?(permission)
      end
      intro = [I18n.t("ui.micro.settings.intro")]
      settings.vat_liable_since.try { |since| intro << I18n.t("ui.micro.switch.vat.already", date: fmt.date(since)) }
      settings.real_regime_since.try { |since| intro << I18n.t("ui.micro.switch.real.already", date: fmt.date(since)) }
      form_page(I18n.t("ui.micro.settings.title"), micro_crumbs, form, reverse("micro:settings"), I18n.t("ui.forms.save"),
        actions: actions, intro: intro.join(" "))
    end
  end
end
