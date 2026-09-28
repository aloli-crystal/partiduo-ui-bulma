# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Rapports personnalisés (`formulaire`, `form_definition` de l'application
  # d'origine) :
  # liste, calcul sur une période (export CSV et PDF du cœur), création,
  # modification et suppression (`accounting.report.write`). Formules
  # contrôlées par le cœur (`check_report`), jamais par l'interface.
  class CustomReportsHandler < ReportScreen
    def screen_code : String
      "reports"
    end

    def filter_names : Array(String)
      [] of String
    end

    def report : Marten::HTTP::Response
      writable = can?(Acc::REPORT_WRITE)
      columns = [
        column("name", "ui.reports.columns.name", sortable: true),
        column("lines", "ui.reports.columns.lines", "amount", secondary: true, sortable: true),
      ]
      columns << Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions") if writable
      rows = Acc.reports(current.actor).map do |definition|
        cells = [
          Table::Cell.new(definition.name, reverse("accounting:report", id: definition.id)),
          Table::Cell.new(definition.lines.size.to_s, sort: BigDecimal.new(definition.lines.size)),
        ]
        if writable
          cells << Table::Cell.new("", actions: [
            link_action("ui.forms.edit", reverse("accounting:report_edit", id: definition.id), "small"),
            post_action("ui.forms.delete", reverse("accounting:report_delete", id: definition.id), "ui.reports.delete_confirm", "small"),
          ])
        end
        Table::Row.new(cells)
      end
      table = Table.new(I18n.t("accounting.menu.acc_reports"), columns, rows, request.path, empty_message: I18n.t("ui.reports.no_reports"),
        id: "pd-reports")
      actions = [] of Screen::Action
      actions << link_action("ui.reports.new_report", reverse("accounting:report_new"), "primary", "plus") if writable
      list_page(I18n.t("accounting.menu.acc_reports"), table, reports_crumbs, "ui.reports.csv_name", actions,
        intro: I18n.t("ui.reports.custom_intro"))
    end
  end

  # Un rapport calculé sur une période.
  class CustomReportHandler < ReportScreen
    # Un seul cookie pour tous les rapports personnalisés : les dates se
    # reprennent d'un rapport à l'autre, et l'en-tête `Cookie` ne grossit
    # pas avec le nombre de rapports consultés (D-UI-035).
    def screen_code : String
      "report"
    end

    def filter_names : Array(String)
      %w[from to]
    end

    def report : Marten::HTTP::Response
      id = id_param
      from, to = bounds
      if format = export_format
        return file_response(Acc.export_report(current.actor, id, format, from, to))
      end
      view = Acc.run_report(current.actor, id, from, to)
      columns = [
        column("position", "ui.reports.columns.position", "mono", secondary: true),
        column("label", "ui.reports.columns.label"),
        column("formula", "ui.reports.columns.formula", "mono", secondary: true),
        column("amount", "ui.reports.columns.amount", "amount"),
      ]
      rows = view.lines.map do |line|
        Table::Row.new([
          Table::Cell.new(line.position.to_s), Table::Cell.new(line.label), Table::Cell.new(line.formula),
          total_cell(line.amount, formula_url(line.formula, view.date_from, view.date_to)),
        ])
      end
      actions = export_actions
      actions << link_action("ui.forms.edit", reverse("accounting:report_edit", id: id)) if can?(Acc::REPORT_WRITE)
      filters = filters_form([date_field("from", "ui.accounts.from", view.date_from), date_field("to", "ui.accounts.to", view.date_to)])
      report_page(view.name, filters,
        [Screen::Section.new(period_label(view.date_from, view.date_to), table: report_table(view.name, columns, rows, "pd-report-lines"))],
        actions: actions)
    end

    # Montant d'une formule d'un seul compte (`[70%]`, `[512]`) : grand livre
    # de ce compte ; formule composée : pas de lien (elle mêle plusieurs
    # consultations).
    private def formula_url(formula : String, from : Time, to : Time) : String?
      match = formula.strip.match(/\A\[([0-9A-Za-z]+)%?\]\z/) || return
      ledger_book_url(match[1], from, to)
    end
  end

  # Création et modification d'un rapport : nom et lignes (libellé,
  # formule). Lignes vides ignorées ; cinq lignes libres ajoutées au
  # formulaire.
  abstract class CustomReportFormHandler < ReportScreen
    BLANK_LINES = 5

    def screen_code : String
      "report_form"
    end

    def filter_names : Array(String)
      [] of String
    end

    def report : Marten::HTTP::Response
      require!("ACCOUNTING", Acc::REPORT_WRITE)
      show(existing, nil)
    end

    def post
      require!("ACCOUNTING", Acc::REPORT_WRITE)
      input = submitted
      result = save(input)
      if saved = result.value?
        flash["success"] = I18n.t("ui.reports.saved", name: saved.name)
        return go(reverse("accounting:report", id: saved.id))
      end
      form = build_form(input.name, input.lines.map { |line| {line.label, line.formula} })
      form.add_errors(result.errors, fmt)
      show(nil, form)
    end

    abstract def existing : Acc::ReportDefinitionView?
    abstract def save(input : Acc::ReportDefinitionInput) : Partiduo::Api::Result(Acc::ReportDefinitionView)
    abstract def form_title : String
    abstract def action_url : String

    private def show(definition : Acc::ReportDefinitionView?, form : Form?) : Marten::HTTP::Response
      form ||= build_form(definition.try(&.name) || "", definition.try(&.lines.map { |line| {line.label, line.formula} }) || [] of {String, String})
      form_page(form_title, reports_crumbs + [crumb("accounting.menu.acc_reports", reverse("accounting:reports"))], form, action_url,
        I18n.t("ui.forms.save"), reverse("accounting:reports"), intro: I18n.t("ui.reports.formula_help"))
    end

    # Lignes envoyées, dans l'ordre, sans les lignes entièrement vides : les
    # erreurs du contrat (`lines[i].formula`) désignent ces positions, et le
    # formulaire réaffiché les reprend dans le même ordre.
    private def submitted : Acc::ReportDefinitionInput
      lines = [] of Acc::ReportLineInput
      index = 0
      while request.data.fetch("lines[#{index}].label", nil) || request.data.fetch("lines[#{index}].formula", nil)
        label = field("lines[#{index}].label")
        formula = field("lines[#{index}].formula")
        lines << Acc::ReportLineInput.new(label, formula) unless label.empty? && formula.empty?
        index += 1
      end
      Acc::ReportDefinitionInput.new(field("name"), lines)
    end

    private def build_form(name : String, lines : Array({String, String})) : Form
      groups = [Form::Group.new(nil, [Form::Field.new("name", I18n.t("ui.reports.columns.name"), value: name, required: true, wide: true)])]
      (lines + Array.new(BLANK_LINES) { {"", ""} }).each_with_index do |(label, formula), index|
        groups << Form::Group.new(I18n.t("ui.reports.line", number: index + 1), [
          Form::Field.new("lines[#{index}].label", I18n.t("ui.reports.columns.label"), value: label),
          Form::Field.new("lines[#{index}].formula", I18n.t("ui.reports.columns.formula"), value: formula, mono: true),
        ])
      end
      Form.new(groups)
    end
  end

  class CustomReportNewHandler < CustomReportFormHandler
    def existing : Acc::ReportDefinitionView?
      nil
    end

    def save(input : Acc::ReportDefinitionInput) : Partiduo::Api::Result(Acc::ReportDefinitionView)
      Acc.create_report(current.actor, input)
    end

    def form_title : String
      I18n.t("ui.reports.new_report")
    end

    def action_url : String
      reverse("accounting:report_new")
    end
  end

  class CustomReportEditHandler < CustomReportFormHandler
    def existing : Acc::ReportDefinitionView?
      Acc.report(current.actor, id_param)
    end

    def save(input : Acc::ReportDefinitionInput) : Partiduo::Api::Result(Acc::ReportDefinitionView)
      Acc.update_report(current.actor, id_param, input)
    end

    def form_title : String
      I18n.t("ui.reports.edit_report")
    end

    def action_url : String
      reverse("accounting:report_edit", id: id_param)
    end
  end

  class CustomReportDeleteHandler < AccountingScreen
    def post
      definition = Partiduo::Api::Accounting.report(current.actor, id_param)
      result = Partiduo::Api::Accounting.delete_report(current.actor, definition.id)
      if result.success?
        flash["success"] = I18n.t("ui.reports.deleted", name: definition.name)
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(reverse("accounting:reports"))
    end
  end
end
