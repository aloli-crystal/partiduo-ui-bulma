# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Éditions de la Comptabilité (lot 3, menu « Éditions ») : balances
  # générale, des tiers et âgée, grand livre, journaux, bilan, compte de
  # résultat, FEC. Tout vient de `Partiduo::Api::Accounting` : l'interface ne
  # calcule aucun solde ; CSV et PDF sont produits par le cœur
  # (`Acc.export`). Critères gardés par écran (`PersistentFilters`,
  # D-UI-035) ; navigation transverse (ADR-005 D5, D-UI-036) : tout numéro
  # de compte ou code de tiers mène à « Comptes et tiers », tout montant
  # agrégé à sa consultation (mouvements → grand livre, soldes → relevé).
  abstract class ReportScreen < AccountingScreen
    # Affichage à l'écran au-delà duquel le détail est tronqué (l'export
    # reste complet).
    MAX_LINES = 2_000

    @filter_errors = [] of {String, String}

    # Nom court et stable de l'écran (cookie des critères).
    abstract def screen_code : String

    # Critères de l'écran (noms des paramètres gardés).
    abstract def filter_names : Array(String)

    abstract def report : Marten::HTTP::Response

    def get
      if redirect = PersistentFilters.apply(request, screen_code, filter_names)
        return redirect
      end
      report
    end

    # --- Critères ----------------------------------------------------------------

    # Date d'un critère ; illisible : erreur sous le champ, `nil`.
    def filter_day(name : String) : Time?
      text = query(name)
      return if text.empty?
      day = fmt.parse_short_date(text, reference_day)
      @filter_errors << {name, I18n.t("ui.forms.invalid_date")} unless day
      day
    end

    # Bornes demandées ; par défaut, du début de l'exercice de la période de
    # travail à la fin de cette période.
    def bounds : {Time?, Time?}
      from = filter_day("from") || (query("from").empty? ? fiscal_year_start : nil)
      to = filter_day("to") || (query("to").empty? ? working_period.try(&.ends_on) : nil)
      {from, to}
    end

    def checked?(name : String) : Bool
      query(name) == "1"
    end

    def ledger_filter : Array(Int64)?
      query("ledger").to_i64?.try { |id| [id] }
    end

    # Journaux lisibles proposés en critère ; sans le droit de lire les
    # journaux, le critère n'est pas proposé.
    def ledger_field : Form::Field?
      ledgers = Acc.ledgers(current.actor).reject(&.access.none?)
      options = [option("", I18n.t("ui.reports.all_ledgers"))] + ledgers.map { |ledger| option(ledger.id.to_s, "#{ledger.code} · #{ledger.name}") }
      Form::Field.new("ledger", I18n.t("ui.entries.ledger"), "select", query("ledger"), options: options)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    def date_field(name : String, label_key : String, value : Time?) : Form::Field
      Form::Field.new(name, I18n.t(label_key), value: query(name).presence || fmt.date(value), mono: true)
    end

    def text_field(name : String, label_key : String, mono : Bool = true) : Form::Field
      Form::Field.new(name, I18n.t(label_key), value: query(name), mono: mono)
    end

    def check_field(name : String, label_key : String) : Form::Field
      Form::Field.new(name, I18n.t(label_key), "checkbox", checked?(name) ? "1" : "")
    end

    def kind_field : Form::Field
      Form::Field.new("kind", I18n.t("ui.reports.card_kind"), "select", query("kind"), options: [
        option("", I18n.t("ui.reports.card_kinds.all")),
        option("customer", I18n.t("ui.reports.card_kinds.customer")),
        option("supplier", I18n.t("ui.reports.card_kinds.supplier")),
      ])
    end

    def card_kind : String?
      {"customer", "supplier"}.find(&.==(query("kind")))
    end

    def filters_form(fields : Array(Form::Field?)) : Form
      form = Form.new([Form::Group.new(nil, fields.compact)])
      @filter_errors.each { |(name, message)| form.add_error(name, message) }
      form
    end

    # --- Exports -----------------------------------------------------------------

    def export_format : Acc::ExportFormat?
      case query("format")
      when "csv" then Acc::ExportFormat::Csv
      when "pdf" then Acc::ExportFormat::Pdf
      end
    end

    def file_response(file : Acc::FileView) : Marten::HTTP::Response
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end

    # Adresse de l'écran avec les critères courants et un format d'export.
    def export_url(format : String) : String
      params = PersistentFilters.pick(request.query_params, filter_names)
      params["format"] = format
      "#{request.path}?#{URI::Params.encode(params)}"
    end

    def export_actions : Array(Screen::Action)
      [
        link_action("ui.table.export_csv", export_url("csv"), icon: "download"),
        link_action("ui.reports.export_pdf", export_url("pdf"), icon: "printer"),
      ]
    end

    def current_params : Hash(String, String)
      PersistentFilters.pick(request.query_params, filter_names)
    end

    # --- Navigation transverse (D-UI-036) ----------------------------------------

    def iso(day : Time?) : String?
      day.try(&.to_s("%Y-%m-%d"))
    end

    # Relevé d'un compte ou d'un tiers sur la période.
    def statement_url(key : String, from : Time?, to : Time?, open : Bool = false) : String
      params = {"q" => key}
      iso(from).try { |text| params["from"] = text }
      iso(to).try { |text| params["to"] = text }
      params["open"] = "1" if open
      "#{reverse("accounting:accounts")}?#{URI::Params.encode(params)}"
    end

    # Grand livre d'un compte (et de ses sous-comptes) ou d'une classe.
    def ledger_book_url(account : String, from : Time?, to : Time?) : String
      params = {"account_from" => account, "account_to" => account}
      iso(from).try { |text| params["from"] = text }
      iso(to).try { |text| params["to"] = text }
      "#{reverse("accounting:general_ledger")}?#{URI::Params.encode(params)}"
    end

    # Grand livre auxiliaire d'un tiers.
    def card_book_url(code : String, from : Time?, to : Time?) : String
      params = {"by_card" => "1", "card" => code}
      iso(from).try { |text| params["from"] = text }
      iso(to).try { |text| params["to"] = text }
      "#{reverse("accounting:general_ledger")}?#{URI::Params.encode(params)}"
    end

    def entry_url(id : Int64?) : String?
      id.try { |value| reverse("accounting:entry", id: value) }
    end

    # Montant affiché (vide si nul), clé de tri, lien facultatif.
    def amount_cell(value : BigDecimal, url : String? = nil, blank_zero : Bool = true) : Table::Cell
      text = blank_zero && value.zero? ? "" : fmt.amount(value)
      Table::Cell.new(text, text.empty? ? nil : url, sort: value, csv: fmt.csv_amount(value))
    end

    def total_cell(value : BigDecimal, url : String? = nil) : Table::Cell
      amount_cell(value, url, blank_zero: false)
    end

    def text_cell(text : String, url : String? = nil) : Table::Cell
      Table::Cell.new(text, text.empty? ? nil : url)
    end

    def date_cell(day : Time?) : Table::Cell
      Table::Cell.new(fmt.date(day), sort: date_key(day), csv: date_key(day))
    end

    def period_label(from : Time, to : Time) : String
      I18n.t("ui.reports.period", from: fmt.date(from), to: fmt.date(to))
    end

    def reports_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.reports")]
    end

    # Page d'une édition (`ui/reports/report.html`).
    def report_page(title : String, filters : Form?, sections : Array(Screen::Section), summary : Array(Screen::Item)? = nil,
                    warnings : Array(String) = [] of String, actions : Array(Screen::Action) = export_actions,
                    intro : String? = nil, submit : String = I18n.t("ui.reports.show"), status : Int32 = 200) : Marten::HTTP::Response
      context["title"] = title
      context["crumbs"] = reports_crumbs
      context["actions"] = actions
      context["filters"] = filters
      context["report_path"] = request.path
      context["submit_label"] = submit
      context["summary"] = summary.try { |items| Screen.listed(items.reject(&.value.empty?)) }
      context["warnings"] = Screen.listed(warnings)
      context["sections"] = sections
      context["intro"] = intro
      page("ui/reports/report.html", status: status)
    end

    # Tableau d'une édition : colonnes non triables (ordre comptable) sauf
    # demande, sans liens d'export (ils sont dans l'en-tête).
    def report_table(caption : String, columns : Array(Table::Column), rows : Array(Table::Row), id : String,
                     footer : Array(Table::Row)? = nil, empty_key : String = "ui.reports.empty") : Table
      table = Table.new(caption, columns, rows, request.path, current_params, empty_message: I18n.t(empty_key), id: id, footer_rows: footer)
      table.exportable = false
      table
    end

    def column(key : String, label_key : String, kind : String = "text", secondary : Bool = false, sortable : Bool = false) : Table::Column
      Table::Column.new(key, I18n.t(label_key), kind, secondary: secondary, sortable: sortable)
    end
  end

  # Balance générale (`Acc_Balance`, `balance.inc.php`).
  class TrialBalanceHandler < ReportScreen
    def screen_code : String
      "trial_balance"
    end

    def filter_names : Array(String)
      %w[from to ledger ledger_kind account_from account_to nonzero]
    end

    def report : Marten::HTTP::Response
      from, to = bounds
      kind = Acc::LedgerKind.parse?(query("ledger_kind").camelcase)
      criteria = Acc::TrialBalanceQuery.new(date_from: from, date_to: to, ledger_ids: ledger_filter,
        ledger_kinds: kind.try { |value| [value] }, account_from: query("account_from").presence,
        account_to: query("account_to").presence, nonzero_only: checked?("nonzero"))
      if format = export_format
        return file_response(Acc.export(current.actor, criteria, format))
      end
      view = Acc.trial_balance(current.actor, criteria)
      from, to = view.date_from, view.date_to
      rows = view.rows.map { |row| balance_row(row, from, to, row.number, "#{row.number} · #{row.label}") }
      table = report_table(I18n.t("accounting.menu.acc_trial_balance"), columns(true), rows, "pd-trial-balance",
        footer: [balance_row(view.total, from, to, nil, I18n.t("ui.reports.total"), "pd-row-total")])
      table.sort!(query("sort")) unless query("sort").empty?
      classes = view.classes.map { |row| balance_row(row, from, to, row.number, I18n.t("ui.reports.class", number: row.number), "pd-row-subtotal") }
      sections = [
        Screen::Section.new(period_label(from, to), table: table),
        Screen::Section.new(I18n.t("ui.reports.by_class"), table: report_table(I18n.t("ui.reports.by_class"), columns(false), classes, "pd-trial-classes")),
      ]
      warnings = [] of String
      warnings << I18n.t("ui.reports.unbalanced", difference: fmt.amount(view.delta)) unless view.delta.zero?
      summary = view.summary
      items = [
        Screen::Item.new(I18n.t("ui.reports.balance_sheet_classes"), fmt.amount(summary.balance_sheet), mono: true),
        Screen::Item.new(I18n.t("ui.reports.expenses"), fmt.amount(summary.expenses), ledger_book_url("6", from, to), mono: true),
        Screen::Item.new(I18n.t("ui.reports.income"), fmt.amount(summary.income), ledger_book_url("7", from, to), mono: true),
        Screen::Item.new(I18n.t("ui.reports.result"), fmt.amount(summary.result), statement_link("income_statement", from, to), mono: true),
      ]
      report_page(I18n.t("accounting.menu.acc_trial_balance"), filters(from, to), sections, items, warnings)
    end

    private def statement_link(route : String, from : Time, to : Time) : String
      "#{reverse("accounting:#{route}")}?#{URI::Params.encode({"from" => iso(from).to_s, "to" => iso(to).to_s})}"
    end

    private def columns(sortable : Bool) : Array(Table::Column)
      [
        column("account", "ui.reports.columns.account", "mono", sortable: sortable),
        column("opening_debit", "ui.reports.columns.opening_debit", "amount", secondary: true, sortable: sortable),
        column("opening_credit", "ui.reports.columns.opening_credit", "amount", secondary: true, sortable: sortable),
        column("debit", "ui.reports.columns.debit", "amount", sortable: sortable),
        column("credit", "ui.reports.columns.credit", "amount", sortable: sortable),
        column("closing_debit", "ui.reports.columns.closing_debit", "amount", sortable: sortable),
        column("closing_credit", "ui.reports.columns.closing_credit", "amount", sortable: sortable),
      ]
    end

    # Compte (ou classe) : numéro → relevé ; mouvements → grand livre ;
    # soldes → relevé de la période.
    private def balance_row(row : Acc::TrialBalanceRowView, from : Time, to : Time, number : String?, label : String, css : String = "") : Table::Row
      statement = number.try { |value| statement_url(value, from, to) }
      book = number.try { |value| ledger_book_url(value, from, to) }
      Table::Row.new([
        Table::Cell.new(label, statement, sort: row.number),
        amount_cell(row.opening.debit, statement),
        amount_cell(row.opening.credit, statement),
        amount_cell(row.debit, book),
        amount_cell(row.credit, book),
        amount_cell(row.closing.debit, statement),
        amount_cell(row.closing.credit, statement),
      ], css)
    end

    private def filters(from : Time?, to : Time?) : Form
      kinds = [option("", I18n.t("ui.reports.all_ledger_kinds"))] +
              Acc::LedgerKind.values.map { |kind| option(kind.code, I18n.t("accounting.ledger_kinds.#{kind.code}")) }
      filters_form([
        date_field("from", "ui.accounts.from", from),
        date_field("to", "ui.accounts.to", to),
        ledger_field,
        Form::Field.new("ledger_kind", I18n.t("ui.reports.ledger_kind"), "select", query("ledger_kind"), options: kinds),
        text_field("account_from", "ui.reports.account_from"),
        text_field("account_to", "ui.reports.account_to"),
        check_field("nonzero", "ui.reports.nonzero_only"),
      ])
    end
  end

  # Balance des tiers (`balance_card.inc.php`).
  class AuxiliaryBalanceHandler < ReportScreen
    def screen_code : String
      "auxiliary_balance"
    end

    def filter_names : Array(String)
      %w[from to kind account ledger nonzero]
    end

    def report : Marten::HTTP::Response
      from, to = bounds
      criteria = Acc::AuxiliaryBalanceQuery.new(date_from: from, date_to: to, kind: card_kind,
        account: query("account").presence, ledger_ids: ledger_filter, nonzero_only: checked?("nonzero"))
      if format = export_format
        return file_response(Acc.export(current.actor, criteria, format))
      end
      view = Acc.auxiliary_balance(current.actor, criteria)
      from, to = view.date_from, view.date_to
      rows = view.rows.map { |row| card_row(row, from, to) }
      total = view.total
      footer = Table::Row.new([
        Table::Cell.new(I18n.t("ui.reports.total")), Table::Cell.new(""), Table::Cell.new(""),
        total_cell(total.opening.signed), total_cell(total.debit), total_cell(total.credit),
        total_cell(total.closing.debit), total_cell(total.closing.credit),
      ], "pd-row-total")
      table = report_table(I18n.t("accounting.menu.acc_auxiliary_balance"), columns, rows, "pd-auxiliary-balance", footer: [footer])
      table.sort!(query("sort")) unless query("sort").empty?
      report_page(I18n.t("accounting.menu.acc_auxiliary_balance"), filters(from, to),
        [Screen::Section.new(period_label(from, to), table: table)])
    end

    private def columns : Array(Table::Column)
      [
        column("code", "ui.reports.columns.card_code", "mono", sortable: true),
        column("name", "ui.reports.columns.card_name", sortable: true),
        column("account", "ui.reports.columns.account", "mono", secondary: true, sortable: true),
        column("opening", "ui.reports.columns.opening", "amount", secondary: true, sortable: true),
        column("debit", "ui.reports.columns.debit", "amount", sortable: true),
        column("credit", "ui.reports.columns.credit", "amount", sortable: true),
        column("closing_debit", "ui.reports.columns.closing_debit", "amount", sortable: true),
        column("closing_credit", "ui.reports.columns.closing_credit", "amount", sortable: true),
      ]
    end

    private def card_row(row : Acc::AuxiliaryBalanceRowView, from : Time, to : Time) : Table::Row
      statement = statement_url(row.card_code, from, to)
      book = card_book_url(row.card_code, from, to)
      account = row.account_number
      Table::Row.new([
        Table::Cell.new(row.card_code, statement),
        Table::Cell.new(row.card_name, statement),
        Table::Cell.new(account || "", account.try { |number| statement_url(number, from, to) }),
        amount_cell(row.opening.signed, statement),
        amount_cell(row.debit, book),
        amount_cell(row.credit, book),
        amount_cell(row.closing.debit, statement),
        amount_cell(row.closing.credit, statement),
      ])
    end

    private def filters(from : Time?, to : Time?) : Form
      filters_form([
        date_field("from", "ui.accounts.from", from),
        date_field("to", "ui.accounts.to", to),
        kind_field,
        text_field("account", "ui.reports.account_prefix"),
        ledger_field,
        check_field("nonzero", "ui.reports.nonzero_only"),
      ])
    end
  end

  # Balance âgée (`Balance_Age`) : reste dû et échu par tiers, tranches ;
  # détail des éléments ouverts pour un tiers choisi.
  class AgedBalanceHandler < ReportScreen
    def screen_code : String
      "aged_balance"
    end

    def filter_names : Array(String)
      %w[as_of kind card ledger]
    end

    def report : Marten::HTTP::Response
      as_of = filter_day("as_of")
      criteria = Acc::AgedBalanceQuery.new(as_of: as_of, kind: card_kind, card: query("card").presence, ledger_ids: ledger_filter)
      if format = export_format
        return file_response(Acc.export(current.actor, criteria, format))
      end
      view = begin
        Acc.aged_balance(current.actor, criteria)
      rescue Partiduo::Api::NotFound
        @filter_errors << {"card", I18n.t("ui.accounts.not_found", q: query("card"))}
        return report_page(I18n.t("accounting.menu.acc_aged_balance"), filters(as_of), [] of Screen::Section, status: 404)
      end
      rows = view.rows.map { |row| card_row(row) }
      footer = Table::Row.new([
        Table::Cell.new(I18n.t("ui.reports.total")), Table::Cell.new(""),
        total_cell(view.remaining), total_cell(view.ageing.not_due), total_cell(view.ageing.days_1_30),
        total_cell(view.ageing.days_31_60), total_cell(view.ageing.over_60), total_cell(view.overdue),
      ], "pd-row-total")
      table = report_table(I18n.t("accounting.menu.acc_aged_balance"), columns, rows, "pd-aged-balance", footer: [footer])
      table.sort!(query("sort")) unless query("sort").empty?
      sections = [Screen::Section.new(I18n.t("ui.reports.as_of", date: fmt.date(view.as_of)), table: table)]
      if query("card").presence && (row = view.rows.first?)
        sections << Screen::Section.new(I18n.t("ui.reports.open_items", name: row.card_name), table: items_table(row))
      end
      report_page(I18n.t("accounting.menu.acc_aged_balance"), filters(view.as_of), sections)
    end

    private def columns : Array(Table::Column)
      [
        column("code", "ui.reports.columns.card_code", "mono", sortable: true),
        column("name", "ui.reports.columns.card_name", sortable: true),
        column("remaining", "ui.reports.columns.remaining", "amount", sortable: true),
        column("not_due", "ui.accounts.buckets.not_due", "amount", secondary: true, sortable: true),
        column("days_1_30", "ui.accounts.buckets.days_1_30", "amount", secondary: true, sortable: true),
        column("days_31_60", "ui.accounts.buckets.days_31_60", "amount", secondary: true, sortable: true),
        column("over_60", "ui.accounts.buckets.over_60", "amount", secondary: true, sortable: true),
        column("overdue", "ui.reports.columns.overdue", "amount", sortable: true),
      ]
    end

    # Tiers → relevé des lignes non lettrées ; tranches → détail du tiers.
    private def card_row(row : Acc::AgedBalanceRowView) : Table::Row
      statement = statement_url(row.card_code, nil, nil, open: true)
      detail = "#{request.path}?#{URI::Params.encode(current_params.merge({"card" => row.card_code}))}"
      Table::Row.new([
        Table::Cell.new(row.card_code, statement),
        Table::Cell.new(row.card_name, statement),
        amount_cell(row.remaining, statement),
        amount_cell(row.ageing.not_due, detail),
        amount_cell(row.ageing.days_1_30, detail),
        amount_cell(row.ageing.days_31_60, detail),
        amount_cell(row.ageing.over_60, detail),
        amount_cell(row.overdue, detail),
      ])
    end

    private def items_table(row : Acc::AgedBalanceRowView) : Table
      columns = [
        column("date", "ui.entries.date", "mono"),
        column("due_date", "ui.entries.due_date", "mono"),
        column("ledger", "ui.entries.ledger", "mono", secondary: true),
        column("receipt", "ui.entries.receipt", "mono"),
        column("label", "ui.entries.label"),
        column("days", "ui.reports.columns.days", "amount", secondary: true),
        column("amount", "ui.entries.amount", "amount"),
        column("letter", "ui.accounts.letter", "mono", secondary: true),
      ]
      rows = row.items.map do |item|
        Table::Row.new([
          date_cell(item.date), date_cell(item.due_date), text_cell(item.ledger_code || ""),
          text_cell(item.receipt || "", entry_url(item.entry_id)), text_cell(item.label),
          Table::Cell.new(item.days > 0 ? item.days.to_s : "", sort: BigDecimal.new(item.days)),
          total_cell(item.amount), text_cell(item.matching_code || ""),
        ])
      end
      report_table(I18n.t("ui.reports.open_items", name: row.card_name), columns, rows, "pd-aged-items")
    end

    private def filters(as_of : Time?) : Form
      filters_form([
        date_field("as_of", "ui.reports.as_of_date", as_of),
        kind_field,
        text_field("card", "ui.reports.card"),
        ledger_field,
      ])
    end
  end

  # Grand livre général ou auxiliaire (`impress_gl_comptes`, `impress_poste`).
  class GeneralLedgerHandler < ReportScreen
    def screen_code : String
      "general_ledger"
    end

    def filter_names : Array(String)
      %w[from to account_from account_to ledger by_card kind card]
    end

    def report : Marten::HTTP::Response
      from, to = bounds
      by_card = checked?("by_card") || !query("card").empty?
      criteria = Acc::GeneralLedgerQuery.new(date_from: from, date_to: to, account_from: query("account_from").presence,
        account_to: query("account_to").presence, ledger_ids: ledger_filter, by_card: by_card, kind: card_kind,
        card: query("card").presence)
      if format = export_format
        return file_response(Acc.export(current.actor, criteria, format))
      end
      view = begin
        Acc.general_ledger(current.actor, criteria)
      rescue Partiduo::Api::NotFound
        @filter_errors << {"card", I18n.t("ui.accounts.not_found", q: query("card"))}
        return report_page(I18n.t("accounting.menu.acc_general_ledger"), filters(from, to), [] of Screen::Section, status: 404)
      end
      from, to = view.date_from, view.date_to
      # Au plus `MAX_LINES` lignes affichées, coupées au besoin à
      # l'intérieur d'une section (un 512 de 50 000 lignes) ; l'export
      # reste complet.
      shown = 0
      truncated = false
      warnings = [] of String
      sections = [] of Screen::Section
      view.sections.each_with_index do |section, index|
        remaining = MAX_LINES - shown
        if remaining <= 0
          truncated = true
          break
        end
        truncated = true if section.lines.size > remaining
        shown += Math.min(section.lines.size, remaining)
        sections << book_section(section, index, view.by_card, from, to, remaining)
      end
      warnings << I18n.t("ui.reports.truncated", count: MAX_LINES) if truncated
      sections << Screen::Section.new(I18n.t("ui.reports.no_moves")) if sections.empty?
      summary = [
        Screen::Item.new(I18n.t("ui.reports.period_label"), period_label(from, to)),
        Screen::Item.new(I18n.t("ui.reports.sections", count: view.sections.size), view.sections.size.to_s, mono: true),
        Screen::Item.new(I18n.t("ui.accounts.total_debit"), fmt.amount(view.total_debit), mono: true),
        Screen::Item.new(I18n.t("ui.accounts.total_credit"), fmt.amount(view.total_credit), mono: true),
      ]
      report_page(I18n.t("accounting.menu.acc_general_ledger"), filters(from, to), sections, summary, warnings)
    end

    private def book_section(section : Acc::GeneralLedgerSectionView, index : Int32, by_card : Bool, from : Time, to : Time,
                             limit : Int32) : Screen::Section
      statement = statement_url(section.key, from, to)
      columns = [
        column("date", "ui.entries.date", "mono"),
        column("ledger", "ui.entries.ledger", "mono", secondary: true),
        column("receipt", "ui.entries.receipt", "mono"),
        column("label", "ui.entries.label"),
        column("other", by_card ? "ui.reports.columns.account" : "ui.entries.card", "mono", secondary: true),
        column("debit", "ui.reports.columns.debit", "amount"),
        column("credit", "ui.reports.columns.credit", "amount"),
        column("balance", "ui.reports.columns.balance", "amount"),
        column("letter", "ui.accounts.letter", "mono", secondary: true),
      ]
      rows = [Table::Row.new([
        Table::Cell.new(fmt.date(from)), Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(I18n.t("ui.accounts.opening")),
        Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(""), total_cell(section.opening_balance, statement), Table::Cell.new(""),
      ], "pd-row-subtotal")]
      rows.concat(section.lines.first(limit).map do |line|
        other = by_card ? line.account_number : line.card_code
        Table::Row.new([
          date_cell(line.date), text_cell(line.ledger_code), text_cell(line.receipt || line.internal_code, entry_url(line.entry_id)),
          text_cell(line.label), text_cell(other || "", other.try { |key| statement_url(key, from, to) }),
          amount_cell(line.debit), amount_cell(line.credit), total_cell(line.balance), text_cell(line.matching_code || ""),
        ])
      end)
      footer = Table::Row.new([
        Table::Cell.new(fmt.date(to)), Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(I18n.t("ui.reports.closing")),
        Table::Cell.new(""), total_cell(section.total_debit), total_cell(section.total_credit),
        total_cell(section.closing_balance, statement), Table::Cell.new(""),
      ], "pd-row-total")
      title = "#{section.key} · #{section.label}"
      table = report_table(title, columns, rows, "pd-gl-#{index + 1}", footer: [footer])
      Screen::Section.new(title, table: table, actions: [link_action("ui.reports.consult", statement, "small")])
    end

    private def filters(from : Time?, to : Time?) : Form
      filters_form([
        date_field("from", "ui.accounts.from", from),
        date_field("to", "ui.accounts.to", to),
        text_field("account_from", "ui.reports.account_from"),
        text_field("account_to", "ui.reports.account_to"),
        ledger_field,
        check_field("by_card", "ui.reports.by_card"),
        kind_field,
        text_field("card", "ui.reports.card"),
      ])
    end
  end

  # Journaux (`impress_jrn`, `Print_Ledger`) : écritures d'un ou de tous les
  # journaux visibles, totaux par mois.
  class JournalsHandler < ReportScreen
    def screen_code : String
      "journals"
    end

    def filter_names : Array(String)
      %w[from to ledger]
    end

    def report : Marten::HTTP::Response
      from, to = journal_bounds
      criteria = Acc::JournalQuery.new(date_from: from, date_to: to, ledger_ids: ledger_filter)
      if format = export_format
        return file_response(Acc.export(current.actor, criteria, format))
      end
      view = Acc.journals(current.actor, criteria)
      from, to = view.date_from, view.date_to
      shown = 0
      truncated = false
      warnings = [] of String
      sections = [] of Screen::Section
      view.ledgers.each_with_index do |ledger, index|
        remaining = MAX_LINES - shown
        if remaining <= 0
          truncated = true
          break
        end
        size = ledger.entries.sum(&.lines.size)
        truncated = true if size > remaining
        shown += Math.min(size, remaining)
        sections << ledger_section(ledger, index, from, to, remaining)
      end
      warnings << I18n.t("ui.reports.truncated", count: MAX_LINES) if truncated
      sections << Screen::Section.new(I18n.t("ui.reports.no_moves")) if sections.empty?
      summary = [
        Screen::Item.new(I18n.t("ui.reports.period_label"), period_label(from, to)),
        Screen::Item.new(I18n.t("ui.reports.entries_count"), view.entries.to_s, mono: true),
        Screen::Item.new(I18n.t("ui.accounts.total_debit"), fmt.amount(view.total_debit), mono: true),
        Screen::Item.new(I18n.t("ui.accounts.total_credit"), fmt.amount(view.total_credit), mono: true),
      ]
      report_page(I18n.t("accounting.menu.acc_journals"), filters(from, to), sections, summary, warnings)
    end

    # Par défaut : la période de travail.
    private def journal_bounds : {Time?, Time?}
      period = working_period
      from = filter_day("from") || (query("from").empty? ? period.try(&.starts_on) : nil)
      to = filter_day("to") || (query("to").empty? ? period.try(&.ends_on) : nil)
      {from, to}
    end

    # Au plus `limit` lignes d'écritures, la dernière écriture pouvant être
    # coupée ; les totaux du pied restent ceux du journal entier.
    private def ledger_section(ledger : Acc::LedgerJournalView, index : Int32, from : Time, to : Time,
                               limit : Int32) : Screen::Section
      columns = [
        column("date", "ui.entries.date", "mono"),
        column("receipt", "ui.entries.receipt", "mono"),
        column("account", "ui.reports.columns.account", "mono"),
        column("card", "ui.entries.card", "mono", secondary: true),
        column("label", "ui.entries.label"),
        column("debit", "ui.reports.columns.debit", "amount"),
        column("credit", "ui.reports.columns.credit", "amount"),
      ]
      rows = [] of Table::Row
      left = limit
      ledger.entries.each do |entry|
        break if left <= 0
        rows << Table::Row.new([
          date_cell(entry.date), text_cell(entry.receipt || entry.internal_code, entry_url(entry.entry_id)),
          Table::Cell.new(""), Table::Cell.new(""), text_cell(entry.label),
          amount_cell(entry.debit, entry_url(entry.entry_id)), amount_cell(entry.credit, entry_url(entry.entry_id)),
        ], "pd-row-section")
        lines = entry.lines.first(left)
        left -= lines.size
        rows.concat(lines.map do |line|
          Table::Row.new([
            Table::Cell.new(""), Table::Cell.new(""),
            text_cell("#{line.account_number} · #{line.account_label}", statement_url(line.account_number, from, to)),
            text_cell(line.card_code || "", line.card_code.try { |code| statement_url(code, from, to) }),
            text_cell(line.label), amount_cell(line.debit), amount_cell(line.credit),
          ])
        end)
      end
      footer = ledger.months.map do |month|
        Table::Row.new([
          Table::Cell.new(month.label), Table::Cell.new(I18n.t("ui.reports.entries", count: month.entries)),
          Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(""),
          total_cell(month.debit), total_cell(month.credit),
        ], "pd-row-subtotal")
      end
      footer << Table::Row.new([
        Table::Cell.new(I18n.t("ui.reports.total")), Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(""),
        total_cell(ledger.total_debit), total_cell(ledger.total_credit),
      ], "pd-row-total")
      title = "#{ledger.ledger_code} · #{ledger.ledger_name}"
      Screen::Section.new(title, table: report_table(title, columns, rows, "pd-journal-#{index + 1}", footer: footer))
    end

    private def filters(from : Time?, to : Time?) : Form
      filters_form([date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to), ledger_field])
    end
  end

  # Bilan et compte de résultat (`Acc_Bilan`) : rubriques du modèle du
  # régime, exercice précédent en regard, comptes non repris et soldes à
  # contre-sens signalés.
  abstract class FinancialStatementHandler < ReportScreen
    abstract def kind : Acc::StatementKind

    def screen_code : String
      kind.code
    end

    def filter_names : Array(String)
      %w[from to regime compare]
    end

    def title : String
      I18n.t("accounting.menu.acc_#{kind.code}")
    end

    def report : Marten::HTTP::Response
      from, to = bounds
      # Sans critère envoyé, l'exercice précédent est affiché en regard.
      compare = checked?("compare") || query("f").empty? && query("compare").empty?
      criteria = Acc::FinancialStatementQuery.new(kind: kind, date_from: from, date_to: to,
        regime: query("regime").presence, compare: compare)
      if format = export_format
        return file_response(Acc.export(current.actor, criteria, format))
      end
      view = begin
        Acc.financial_statement(current.actor, criteria)
      rescue Partiduo::Api::NotFound
        @filter_errors << {"regime", I18n.t("ui.reports.no_statement")}
        return report_page(title, filters(from, to, compare), [] of Screen::Section, status: 404)
      end
      from, to = view.date_from, view.date_to
      sections = [Screen::Section.new(period_label(from, to), table: statement_table(view))]
      unless view.unmapped.empty?
        sections << Screen::Section.new(I18n.t("ui.reports.unmapped"), table: accounts_table(view.unmapped, "pd-unmapped", from, to))
      end
      unless view.anomalies.empty?
        sections << Screen::Section.new(I18n.t("ui.reports.anomalies"), table: accounts_table(view.anomalies, "pd-anomalies", from, to))
      end
      report_page(title, filters(from, to, compare), sections, summary(view, from, to), warnings(view))
    end

    private def warnings(view : Acc::FinancialStatementView) : Array(String)
      warnings = [] of String
      warnings << I18n.t("ui.reports.statement_partial") if view.partial
      if kind.balance_sheet? && !view.difference.zero?
        warnings << I18n.t("ui.reports.sheet_difference", difference: fmt.amount(view.difference))
      end
      warnings << I18n.t("ui.reports.unmapped_warning", count: view.unmapped.size) unless view.unmapped.empty?
      warnings
    end

    # Résultat → l'autre état ; comptes détaillés → balance de la période.
    private def summary(view : Acc::FinancialStatementView, from : Time, to : Time) : Array(Screen::Item)
      dates = URI::Params.encode({"from" => iso(from).to_s, "to" => iso(to).to_s})
      other = kind.balance_sheet? ? "income_statement" : "balance_sheet"
      summary = [
        Screen::Item.new(I18n.t("ui.reports.regime"), I18n.t("ui.reports.regimes.#{view.regime}")),
        Screen::Item.new(I18n.t("ui.reports.result"), fmt.amount(view.result), "#{reverse("accounting:#{other}")}?#{dates}", mono: true),
        Screen::Item.new(I18n.t("ui.reports.trial_balance_link"), I18n.t("accounting.menu.acc_trial_balance"),
          "#{reverse("accounting:trial_balance")}?#{dates}"),
      ]
      if previous_from = view.previous_from
        summary << Screen::Item.new(I18n.t("ui.reports.previous"), period_label(previous_from, view.previous_to || previous_from))
      end
      summary
    end

    private def statement_table(view : Acc::FinancialStatementView) : Table
      sheet = kind.balance_sheet?
      compare = !view.previous_from.nil?
      columns = [column("label", "ui.reports.columns.heading")]
      if sheet
        columns << column("gross", "ui.reports.columns.gross", "amount", secondary: true)
        columns << column("less", "ui.reports.columns.less", "amount", secondary: true)
      end
      columns << column("net", sheet ? "ui.reports.columns.net" : "ui.reports.columns.amount", "amount")
      columns << column("previous", "ui.reports.columns.previous", "amount", secondary: true) if compare
      rows = view.lines.map do |line|
        label = Table::Cell.new(I18n.t(line.label_key))
        label.css = "pd-indent-#{line.level.clamp(0, 3)}" if line.level > 0
        cells = [label]
        if sheet
          cells << optional_amount(line.gross)
          cells << optional_amount(line.less)
        end
        cells << optional_amount(line.net)
        cells << optional_amount(line.previous) if compare
        css = case line.style
              when "heading"  then "pd-row-heading"
              when "subtotal" then "pd-row-subtotal"
              when "total"    then "pd-row-total"
              else                 ""
              end
        Table::Row.new(cells, css)
      end
      report_table(title, columns, rows, "pd-statement")
    end

    private def optional_amount(value : BigDecimal?) : Table::Cell
      value ? total_cell(value) : Table::Cell.new("")
    end

    # Comptes signalés : chacun mène à son relevé.
    private def accounts_table(accounts : Array(Acc::StatementAccountView), id : String, from : Time, to : Time) : Table
      columns = [
        column("account", "ui.reports.columns.account", "mono"),
        column("kind", "ui.reports.columns.kind", secondary: true),
        column("balance", "ui.reports.columns.balance", "amount"),
      ]
      rows = accounts.map do |account|
        url = statement_url(account.number, from, to)
        Table::Row.new([
          Table::Cell.new("#{account.number} · #{account.label}", url),
          Table::Cell.new(account.kind.try { |value| I18n.t("accounting.account_kinds.#{value.code}") } || ""),
          total_cell(account.balance, url),
        ])
      end
      report_table(id, columns, rows, id)
    end

    private def filters(from : Time?, to : Time?, compare : Bool) : Form
      regimes = begin
        Acc.statement_regimes(current.actor)
      rescue Partiduo::Api::AccessDenied
        [] of String
      end
      options = [option("", I18n.t("ui.reports.instance_regime"))] + regimes.map { |code| option(code, I18n.t("ui.reports.regimes.#{code}")) }
      filters_form([
        date_field("from", "ui.accounts.from", from),
        date_field("to", "ui.accounts.to", to),
        Form::Field.new("regime", I18n.t("ui.reports.regime"), "select", query("regime"), options: options),
        Form::Field.new("compare", I18n.t("ui.reports.compare"), "checkbox", compare ? "1" : ""),
      ])
    end
  end

  class BalanceSheetHandler < FinancialStatementHandler
    def kind : Acc::StatementKind
      Acc::StatementKind::BalanceSheet
    end
  end

  class IncomeStatementHandler < FinancialStatementHandler
    def kind : Acc::StatementKind
      Acc::StatementKind::IncomeStatement
    end
  end

  # FEC (article A47 A-1 du LPF) : exercice, séparateur, encodage ; le
  # fichier est produit par le cœur, qui refuse un FEC incomplet.
  class FecHandler < ReportScreen
    def screen_code : String
      "fec"
    end

    def filter_names : Array(String)
      %w[fiscal_year separator encoding]
    end

    def report : Marten::HTTP::Response
      # Le formulaire n'appelle le cœur qu'au téléchargement : le droit est
      # vérifié dès l'affichage, comme pour les autres éditions.
      require!("ACCOUNTING", Acc::REPORT_READ)
      years = Partiduo::Api::Core.fiscal_years(current.actor)
      default_year = working_period.try(&.fiscal_year_id) || years.last?.try(&.id)
      year_id = query("fiscal_year").to_i64? || default_year
      separator = query("separator") == "tab" ? Acc::FecSeparator::Tab : Acc::FecSeparator::Pipe
      encoding = query("encoding") == "utf8" ? Acc::FecEncoding::Utf8 : Acc::FecEncoding::Iso885915
      errors = [] of Partiduo::Api::FieldError
      if query("download") == "1"
        result = Acc.fec(current.actor, Acc::FecQuery.new(fiscal_year_id: year_id, separator: separator, encoding: encoding))
        if file = result.value?
          return file_response(file)
        end
        errors = result.errors
      end
      options = years.map { |year| option(year.id.to_s, year.label) }
      form = Form.new([Form::Group.new(nil, [
        Form::Field.new("fiscal_year", I18n.t("ui.reports.fiscal_year"), "select", year_id.to_s, options: options),
        Form::Field.new("separator", I18n.t("ui.reports.fec_separator"), "select", separator.tab? ? "tab" : "pipe", options: [
          option("pipe", I18n.t("ui.reports.fec_separators.pipe")), option("tab", I18n.t("ui.reports.fec_separators.tab")),
        ]),
        Form::Field.new("encoding", I18n.t("ui.reports.fec_encoding"), "select", encoding.utf8? ? "utf8" : "latin9", options: [
          option("latin9", I18n.t("ui.reports.fec_encodings.latin9")), option("utf8", I18n.t("ui.reports.fec_encodings.utf8")),
        ]),
        Form::Field.new("download", "", "hidden", "1"),
      ])])
      errors.each do |error|
        name = error.field == "date_from" ? "fiscal_year" : error.field
        form.add_error(name, fmt.message(error))
      end
      report_page(I18n.t("accounting.menu.acc_fec"), form, [] of Screen::Section, actions: [] of Screen::Action,
        intro: I18n.t("ui.reports.fec_intro"), submit: I18n.t("ui.reports.fec_download"),
        status: errors.empty? ? 200 : 422)
    end
  end
end
