# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Éditions analytiques (menu `analytic:reports`, successeurs de
  # `anc_balance_simple.inc.php`, `anc_balance_double.inc.php`,
  # `anc_group_balance.inc.php`, `anc_history.inc.php`,
  # `anc_great_ledger.inc.php`, `anc_acc_table.inc.php`,
  # `anc_acc_balance.inc.php`) et contrôle des lignes non ventilées. Tout
  # vient de `Partiduo::Api::Analytic` : l'interface ne calcule aucun
  # solde ; les exports CSV sont produits par le cœur. Onglets entre les
  # éditions, critères gardés par écran (D-UI-035), navigation transverse :
  # un poste mène à son grand livre, une opération à son écriture.
  abstract class AnalyticReportScreen < ReportScreen
    alias Ana = Partiduo::Api::Analytic

    TABS = {
      "reports"       => "ui.analytic.reports.balance",
      "cross_balance" => "ui.analytic.reports.cross_balance",
      "group_balance" => "ui.analytic.reports.group_balance",
      "history"       => "ui.analytic.reports.history",
      "ledger"        => "ui.analytic.reports.ledger",
      "table"         => "ui.analytic.reports.table",
      "undistributed" => "ui.analytic.reports.undistributed",
    }

    @plans : Array(Ana::PlanView)?

    # Nom de route de l'écran (onglet courant).
    abstract def route : String

    def screen_code : String
      "analytic_#{route}"
    end

    def title : String
      I18n.t(TABS[route])
    end

    def plans : Array(Ana::PlanView)
      @plans ||= Ana.plans(current.actor)
    end

    def reports_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.analytic"), crumb("analytic.menu.ana_reports", reverse("analytic:reports"))]
    end

    def tabs : Array(Screen::Tab)
      TABS.map { |name, key| Screen::Tab.new(I18n.t(key), reverse("analytic:#{name}"), name == route) }
    end

    # Plan demandé ; par défaut, le premier.
    def plan_id(name : String = "plan", fallback : Int32 = 0) : Int64?
      requested = query(name).to_i64?
      return requested if requested && plans.any?(&.id.==(requested))
      plans[fallback]?.try(&.id) || plans.first?.try(&.id)
    end

    def plan_field(name : String = "plan", label_key : String = "ui.analytic.plan", selected : Int64? = plan_id) : Form::Field
      Form::Field.new(name, I18n.t(label_key), "select", selected.to_s, options: plans.map { |plan| option(plan.id.to_s, plan.name) })
    end

    def post_fields(from : String = "post_from", to : String = "post_to") : Array(Form::Field?)
      [text_field(from, "ui.analytic.post_from"), text_field(to, "ui.analytic.post_to")] of Form::Field?
    end

    def report_query(plan : Int64, from : Time?, to : Time?) : Ana::ReportQuery
      Ana::ReportQuery.new(plan_id: plan, date_from: from, date_to: to, post_from: query("post_from").presence,
        post_to: query("post_to").presence)
    end

    def export_actions : Array(Screen::Action)
      [link_action("ui.table.export_csv", export_url("csv"), icon: "download"),
       link_action("ui.reports.export_pdf", export_url("pdf"), icon: "printer")]
    end

    def ana_file_response(file : Ana::FileView) : Marten::HTTP::Response
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end

    # Grand livre d'un poste sur la période.
    def post_ledger_url(plan : Int64, code : String, from : Time?, to : Time?) : String
      params = {"plan" => plan.to_s, "post_from" => code, "post_to" => code, "f" => "1"}
      from.try { |day| params["from"] = fmt.date(day) }
      to.try { |day| params["to"] = fmt.date(day) }
      "#{reverse("analytic:ledger")}?#{URI::Params.encode(params)}"
    end

    def operation_url(operation : Ana::OperationView) : String?
      if operation.kind == "misc"
        reverse("analytic:misc_operation", id: operation.distribution_id)
      else
        entry_url(operation.entry_id)
      end
    end

    def partial_warning(partial : Bool) : Array(String)
      partial ? [I18n.t("ui.analytic.reports.partial")] : [] of String
    end

    # Écran sans plan : message, pas de critères.
    def no_plan_page : Marten::HTTP::Response
      context["tabs"] = tabs
      context["tabs_label"] = I18n.t("analytic.menu.ana_reports")
      report_page(title, nil, [] of Screen::Section, actions: [] of Screen::Action, intro: I18n.t("ui.analytic.no_plans"))
    end

    def analytic_page(filters : Form, sections : Array(Screen::Section), summary : Array(Screen::Item)? = nil,
                      warnings = [] of String, actions : Array(Screen::Action) = export_actions) : Marten::HTTP::Response
      context["tabs"] = tabs
      context["tabs_label"] = I18n.t("analytic.menu.ana_reports")
      report_page(title, filters, sections, summary, warnings, actions)
    end

    def amounts_cells(amounts : Ana::Amounts, url : String? = nil) : Array(Table::Cell)
      [
        amount_cell(amounts.debit, url),
        amount_cell(amounts.credit, url),
        amount_cell(amounts.balance, url),
        Table::Cell.new(side_label(amounts.side)),
      ]
    end

    def side_label(side : Partiduo::Api::Accounting::Side?) : String
      return "" unless side
      I18n.t(side.debit? ? "ui.analytic.side_debit" : "ui.analytic.side_credit")
    end

    def amount_columns : Array(Table::Column)
      [
        column("debit", "ui.analytic.debit", "amount"),
        column("credit", "ui.analytic.credit", "amount"),
        column("balance", "ui.analytic.balance", "amount"),
        column("side", "ui.analytic.side"),
      ]
    end
  end

  # Balance simple d'un plan (`Anc_Balance_Simple`).
  class AnalyticBalanceHandler < AnalyticReportScreen
    def route : String
      "reports"
    end

    def filter_names : Array(String)
      %w[plan from to post_from post_to]
    end

    def report : Marten::HTTP::Response
      plan = plan_id || return no_plan_page
      from, to = bounds
      criteria = report_query(plan, from, to)
      return ana_file_response(Ana.export_balance(current.actor, criteria)) if csv?
      view = Ana.balance(current.actor, criteria)
      columns = [column("post", "ui.analytic.post", "mono"), column("description", "ui.analytic.description"),
                 column("group", "ui.analytic.group", "mono", secondary: true)] + amount_columns
      rows = view.rows.map do |row|
        url = post_ledger_url(plan, row.post.code, from, to)
        Table::Row.new([Table::Cell.new(row.post.code, url), Table::Cell.new(row.post.description),
                        Table::Cell.new(row.group_code || "")] + amounts_cells(row.amounts, url))
      end
      total = Table::Row.new([Table::Cell.new(I18n.t("ui.reports.total")), Table::Cell.new(""), Table::Cell.new("")] +
                             amounts_cells(view.total), "pd-row-total")
      table = report_table(title, columns, rows, "pd-analytic-balance", footer: [total])
      analytic_page(filters(from, to), [Screen::Section.new(view.plan.name, table: table)], warnings: partial_warning(view.partial))
    end

    private def filters(from : Time?, to : Time?) : Form
      filters_form([plan_field, date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to)] + post_fields)
    end
  end

  # Balance croisée de deux plans (`Anc_Balance_Double`).
  class AnalyticCrossBalanceHandler < AnalyticReportScreen
    def route : String
      "cross_balance"
    end

    def filter_names : Array(String)
      %w[plan other_plan from to post_from post_to other_post_from other_post_to]
    end

    def report : Marten::HTTP::Response
      plan = plan_id || return no_plan_page
      other = plan_id("other_plan", 1) || plan
      from, to = bounds
      criteria = Ana::CrossBalanceQuery.new(plan_id: plan, other_plan_id: other, date_from: from, date_to: to,
        post_from: query("post_from").presence, post_to: query("post_to").presence,
        other_post_from: query("other_post_from").presence, other_post_to: query("other_post_to").presence)
      return ana_file_response(Ana.export_cross_balance(current.actor, criteria)) if csv?
      view = Ana.cross_balance(current.actor, criteria)
      columns = [column("post", "ui.analytic.post", "mono"), column("other_post", "ui.analytic.other_post", "mono")] + amount_columns
      rows = [] of Table::Row
      view.subtotals.each do |subtotal|
        view.rows.select(&.post.id.==(subtotal.post.id)).each do |row|
          rows << Table::Row.new([
            Table::Cell.new(row.post.code, post_ledger_url(plan, row.post.code, from, to)),
            Table::Cell.new(row.other_post.code, post_ledger_url(other, row.other_post.code, from, to)),
          ] + amounts_cells(row.amounts))
        end
        rows << Table::Row.new([Table::Cell.new(I18n.t("ui.analytic.subtotal", post: subtotal.post.code)), Table::Cell.new("")] +
                               amounts_cells(subtotal.amounts), "pd-row-subtotal")
      end
      total = Table::Row.new([Table::Cell.new(I18n.t("ui.reports.total")), Table::Cell.new("")] + amounts_cells(view.total), "pd-row-total")
      table = report_table(title, columns, rows, "pd-analytic-cross", footer: [total])
      section = Screen::Section.new("#{view.plan.name} × #{view.other_plan.name}", table: table)
      analytic_page(filters(from, to, other), [section], warnings: partial_warning(view.partial))
    end

    private def filters(from : Time?, to : Time?, other : Int64) : Form
      filters_form([plan_field, plan_field("other_plan", "ui.analytic.other_plan", other),
                    date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to)] +
                   post_fields + post_fields("other_post_from", "other_post_to"))
    end
  end

  # Balance par groupe (`Anc_Group::get_result`).
  class AnalyticGroupBalanceHandler < AnalyticReportScreen
    def route : String
      "group_balance"
    end

    def filter_names : Array(String)
      %w[plan from to post_from post_to]
    end

    def report : Marten::HTTP::Response
      plan = plan_id || return no_plan_page
      from, to = bounds
      criteria = report_query(plan, from, to)
      return ana_file_response(Ana.export_group_balance(current.actor, criteria)) if csv?
      view = Ana.group_balance(current.actor, criteria)
      columns = [column("post", "ui.analytic.post", "mono"), column("description", "ui.analytic.description")] + amount_columns
      sections = view.sections.map_with_index do |section, index|
        rows = section.rows.map do |row|
          url = post_ledger_url(plan, row.post.code, from, to)
          Table::Row.new([Table::Cell.new(row.post.code, url), Table::Cell.new(row.post.description)] + amounts_cells(row.amounts, url))
        end
        total = Table::Row.new([Table::Cell.new(I18n.t("ui.reports.total")), Table::Cell.new("")] + amounts_cells(section.total), "pd-row-subtotal")
        heading = section.group_code.try { |code| section.group_description.presence ? "#{code} · #{section.group_description}" : code } ||
                  I18n.t("ui.analytic.without_group")
        Screen::Section.new(heading, table: report_table(heading, columns, rows, "pd-analytic-group-#{index}", footer: [total]))
      end
      summary = [Screen::Item.new(I18n.t("ui.reports.total"), "#{fmt.amount(view.total.balance)} #{side_label(view.total.side)}".strip, mono: true)]
      analytic_page(filters(from, to), sections, summary, partial_warning(view.partial))
    end

    private def filters(from : Time?, to : Time?) : Form
      filters_form([plan_field, date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to)] + post_fields)
    end
  end

  # Historique des imputations (`Anc_Listing`), par pages de 500.
  class AnalyticHistoryHandler < AnalyticReportScreen
    PER_PAGE = 500

    def route : String
      "history"
    end

    def filter_names : Array(String)
      %w[plan from to post_from post_to]
    end

    def report : Marten::HTTP::Response
      plan = plan_id || return no_plan_page
      from, to = bounds
      criteria = report_query(plan, from, to)
      return ana_file_response(Ana.export_history(current.actor, criteria)) if csv?
      page_number = {query("page").to_i? || 1, 1}.max
      # PDF : toutes les opérations (limite du contrat), pas la seule page.
      view = pdf? ? Ana.history(current.actor, criteria, 0, 10_000) : Ana.history(current.actor, criteria, (page_number - 1) * PER_PAGE, PER_PAGE)
      columns = [
        column("date", "ui.analytic.date", "mono"), column("post", "ui.analytic.post", "mono"),
        column("ledger", "ui.analytic.ledger", "mono", secondary: true), column("receipt", "ui.analytic.receipt", "mono"),
        column("account", "ui.analytic.account", "mono", secondary: true), column("card", "ui.analytic.card", "mono", secondary: true),
        column("description", "ui.analytic.description"),
        column("debit", "ui.analytic.debit", "amount"), column("credit", "ui.analytic.credit", "amount"),
      ]
      rows = view.operations.map do |operation|
        link = operation_url(operation)
        Table::Row.new([
          date_cell(operation.date),
          Table::Cell.new(operation.post.code, post_ledger_url(plan, operation.post.code, from, to)),
          Table::Cell.new(operation.ledger_code),
          text_cell(operation.receipt.presence || operation.internal_code, link),
          Table::Cell.new(operation.account_number),
          Table::Cell.new(operation.card_code || ""),
          Table::Cell.new(operation.description),
          amount_cell(operation.debit), amount_cell(operation.credit),
        ])
      end
      blanks = Array.new(7) { Table::Cell.new("") }
      blanks[0] = Table::Cell.new(I18n.t("ui.reports.total"))
      total = Table::Row.new(blanks + [total_cell(view.total.debit), total_cell(view.total.credit)], "pd-row-total")
      table = report_table(title, columns, rows, "pd-analytic-history", footer: [total])
      sections = [Screen::Section.new(view.plan.name, table: table)]
      summary = [Screen::Item.new(I18n.t("ui.analytic.reports.count"), view.count.to_s, mono: true)]
      pages = (view.count + PER_PAGE - 1) // PER_PAGE
      if pages > 1
        links = (1..pages).map do |number|
          params = current_params.merge({"page" => number.to_s})
          Screen::Action.new(number.to_s, "#{request.path}?#{URI::Params.encode(params)}", "get", number == page_number ? "primary" : "small")
        end
        sections << Screen::Section.new(I18n.t("ui.analytic.reports.pages"), note: I18n.t("ui.analytic.reports.page_of", page: page_number, pages: pages), actions: links)
      end
      analytic_page(filters(from, to), sections, summary, partial_warning(view.partial))
    end

    private def filters(from : Time?, to : Time?) : Form
      filters_form([plan_field, date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to)] + post_fields)
    end
  end

  # Grand livre analytique (`Anc_GrandLivre`) : une rubrique par poste,
  # solde progressif ; affichage tronqué à `MAX_LINES` lignes.
  class AnalyticLedgerHandler < AnalyticReportScreen
    def route : String
      "ledger"
    end

    def filter_names : Array(String)
      %w[plan from to post_from post_to]
    end

    def report : Marten::HTTP::Response
      plan = plan_id || return no_plan_page
      from, to = bounds
      criteria = report_query(plan, from, to)
      return ana_file_response(Ana.export_ledger(current.actor, criteria)) if csv?
      view = Ana.ledger(current.actor, criteria)
      columns = [
        column("date", "ui.analytic.date", "mono"), column("receipt", "ui.analytic.receipt", "mono"),
        column("account", "ui.analytic.account", "mono", secondary: true), column("card", "ui.analytic.card", "mono", secondary: true),
        column("description", "ui.analytic.description"),
        column("debit", "ui.analytic.debit", "amount"), column("credit", "ui.analytic.credit", "amount"),
        column("running", "ui.analytic.running", "amount"),
      ]
      remaining = MAX_LINES
      truncated = false
      sections = view.sections.map_with_index do |section, index|
        shown = section.lines.first({remaining, 0}.max)
        truncated = true if shown.size < section.lines.size
        remaining -= shown.size
        rows = shown.map do |line|
          operation = line.operation
          Table::Row.new([
            date_cell(operation.date),
            text_cell(operation.receipt.presence || operation.internal_code, operation_url(operation)),
            Table::Cell.new(operation.account_number),
            Table::Cell.new(operation.card_code || ""),
            Table::Cell.new(operation.description),
            amount_cell(operation.debit), amount_cell(operation.credit),
            total_cell(line.running),
          ])
        end
        total = Table::Row.new([Table::Cell.new(I18n.t("ui.reports.total"))] + Array.new(4) { Table::Cell.new("") } +
                               [total_cell(section.total.debit), total_cell(section.total.credit), total_cell(section.total.signed)], "pd-row-subtotal")
        heading = section.post.description.empty? ? section.post.code : "#{section.post.code} · #{section.post.description}"
        Screen::Section.new(heading, table: report_table(heading, columns, rows, "pd-analytic-ledger-#{index}", footer: [total]))
      end
      warnings = partial_warning(view.partial)
      warnings << I18n.t("ui.reports.truncated", count: MAX_LINES) if truncated
      summary = [
        Screen::Item.new(I18n.t("ui.analytic.debit"), fmt.amount(view.total.debit), mono: true),
        Screen::Item.new(I18n.t("ui.analytic.credit"), fmt.amount(view.total.credit), mono: true),
      ]
      analytic_page(filters(from, to), sections, summary, warnings)
    end

    private def filters(from : Time?, to : Time?) : Form
      filters_form([plan_field, date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to)] + post_fields)
    end
  end

  # Tableau postes × comptes généraux ou fiches (`Anc_Table`, `Anc_Acc_List`) :
  # montants signés crédit − débit.
  class AnalyticTableHandler < AnalyticReportScreen
    def route : String
      "table"
    end

    def filter_names : Array(String)
      %w[plan axis from to post_from post_to]
    end

    def report : Marten::HTTP::Response
      plan = plan_id || return no_plan_page
      from, to = bounds
      axis = query("axis") == "card" ? Ana::TableAxis::Card : Ana::TableAxis::Account
      criteria = Ana::TableQuery.new(plan_id: plan, axis: axis, date_from: from, date_to: to,
        post_from: query("post_from").presence, post_to: query("post_to").presence)
      return ana_file_response(Ana.export_table(current.actor, criteria)) if csv?
      view = Ana.table(current.actor, criteria)
      key_label = axis.card? ? "ui.analytic.card" : "ui.analytic.account"
      columns = [column("key", key_label, "mono"), column("label", "ui.analytic.label")] +
                view.posts.map { |post| Table::Column.new("p#{post.id}", post.code, "amount", sortable: false) } +
                [column("total", "ui.reports.total", "amount")]
      rows = view.rows.map do |row|
        link = axis.card? ? statement_url(row.key, from, to) : ledger_book_url(row.key, from, to)
        cells = [Table::Cell.new(row.key, link), Table::Cell.new(row.label)]
        view.posts.each { |post| cells << amount_cell(row.amounts[post.id]? || BigDecimal.new(0)) }
        cells << total_cell(row.total)
        Table::Row.new(cells)
      end
      footer = [Table::Cell.new(I18n.t("ui.reports.total")), Table::Cell.new("")]
      view.posts.each do |post|
        footer << total_cell(view.column_totals[post.id]? || BigDecimal.new(0), post_ledger_url(plan, post.code, from, to))
      end
      footer << total_cell(view.total)
      table = report_table(title, columns, rows, "pd-analytic-table", footer: [Table::Row.new(footer, "pd-row-total")])
      analytic_page(filters(from, to), [Screen::Section.new(view.plan.name, table: table)], warnings: partial_warning(view.partial))
    end

    private def filters(from : Time?, to : Time?) : Form
      axes = [option("account", I18n.t("ui.analytic.axis_account")), option("card", I18n.t("ui.analytic.axis_card"))]
      filters_form([plan_field, Form::Field.new("axis", I18n.t("ui.analytic.axis"), "select", query("axis").presence || "account", options: axes),
                    date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to)] + post_fields)
    end
  end

  # Contrôle : lignes des comptes ventilés dont la ventilation manque ou
  # n'atteint pas le montant de la ligne dans un plan.
  class AnalyticUndistributedHandler < AnalyticReportScreen
    def route : String
      "undistributed"
    end

    def filter_names : Array(String)
      %w[from to]
    end

    def report : Marten::HTTP::Response
      return no_plan_page if plans.empty?
      from, to = bounds
      from ||= Time.utc(Partiduo::Api::Core.today.year, 1, 1)
      to ||= Partiduo::Api::Core.today
      lines = Ana.undistributed_lines(current.actor, from, to)
      names = plans.to_h { |plan| {plan.id, plan.name} }
      writer = can?("analytic.operation.write")
      columns = [
        column("date", "ui.analytic.date", "mono"), column("ledger", "ui.analytic.ledger", "mono"),
        column("entry", "ui.analytic.receipt", "mono"), column("account", "ui.analytic.account", "mono"),
        column("amount", "ui.analytic.amount", "amount"), column("plans", "ui.analytic.missing_plans"),
        column("actions", "ui.forms.actions"),
      ]
      rows = lines.map do |line|
        actions = [] of Screen::Action
        if writer
          actions << Screen::Action.new(I18n.t("ui.analytic.distribute"), reverse("analytic:entry_distribution", id: line.entry_id), "get", "small")
        end
        Table::Row.new([
          date_cell(line.date),
          Table::Cell.new(line.ledger_code),
          text_cell(line.internal_code, entry_url(line.entry_id)),
          Table::Cell.new("#{line.position + 1} · #{line.account_number}"),
          amount_cell(line.amount),
          Table::Cell.new(line.missing_plan_ids.compact_map { |id| names[id]? }.join(", ")),
          Table::Cell.new("", actions: actions),
        ])
      end
      table = report_table(title, columns, rows, "pd-analytic-undistributed", empty_key: "ui.analytic.reports.all_distributed")
      table.exportable = false
      summary = [Screen::Item.new(I18n.t("ui.analytic.reports.count"), lines.size.to_s, mono: true)]
      analytic_page(filters_form([date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to)]),
        [Screen::Section.new(period_label(from, to), table: table)], summary, actions: [] of Screen::Action)
    end
  end
end
