# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Livre-journal des recettes et des dépenses professionnelles (ADR-007
  # D6) : liste de l'année (tout le livre-journal, ou les recettes, ou les
  # dépenses du mode simplifié), totaux et ventilation par rubrique,
  # éditions CSV et PDF du contrat ; saisie en quelques champs avec choix de
  # la rubrique (nature), pensée d'abord pour le téléphone ; consultation
  # d'une ligne et annulation par contre-passation datée du jour (une ligne
  # inscrite ne se modifie jamais).
  abstract class JournalScreen < LiberalScreen
    # Sens présenté : `receipt`, `expense`, `nil` pour tout le livre-journal.
    abstract def kind : String?

    def list_url : String
      case kind
      when "receipt" then reverse("liberal:receipts")
      when "expense" then reverse("liberal:expenses")
      else                reverse("liberal:journal")
      end
    end

    def new_url(line_kind : String) : String
      reverse(line_kind == "receipt" ? "liberal:receipt_new" : "liberal:expense_new")
    end

    # Clé i18n de l'écran (`ui.liberal.receipt.title`, `ui.liberal.journal.title`).
    def t(key : String, params = {} of String => String) : String
      I18n.t("ui.liberal.#{kind || "journal"}.#{key}", params)
    end

    def list_crumbs : Array(Screen::Crumb)
      liberal_crumbs << Screen::Crumb.new(t("title"), list_url)
    end

    def year_query(year : Int32) : Liberal::JournalQuery
      Liberal::JournalQuery.new(from: Time.utc(year, 1, 1), to: Time.utc(year, 12, 31), kind: kind, limit: Liberal::MAX_LIMIT)
    end
  end

  module ReceiptJournal
    def kind : String?
      "receipt"
    end
  end

  module ExpenseJournal
    def kind : String?
      "expense"
    end
  end

  module WholeJournal
    def kind : String?
      nil
    end
  end

  # Liste de l'année (au plus `MAX_LIMIT` lignes, les plus récentes),
  # totaux et ventilation par rubrique au pied, éditions `?format=csv|pdf`.
  abstract class JournalListHandler < JournalScreen
    def get
      year = year_param
      query = year_query(year)
      if query("format").in?("csv", "pdf")
        format = query("format") == "pdf" ? Liberal::ExportFormat::Pdf : Liberal::ExportFormat::Csv
        return file_response(Liberal.export_journal(current.actor, query, format))
      end
      summary = Liberal.journal_totals(current.actor, query)
      offset = Math.max(summary.count - Liberal::MAX_LIMIT, 0)
      rows = Liberal.lines(current.actor, query.copy_with(offset: offset)).reverse!
      table = Table.new("#{t("title")} #{year}", columns, rows.map { |item| row(item) }, list_url, {"year" => year.to_s},
        empty_message: t("empty"), footer_rows: footers(year, summary))
      table.pdf = true
      actions = [] of Screen::Action
      if can?(WRITE)
        actions << link_action("ui.liberal.receipt.new", new_url("receipt"), kind == "expense" ? "" : "primary", "plus") unless kind == "expense"
        actions << link_action("ui.liberal.expense.new", new_url("expense"), kind == "expense" ? "primary" : "", "plus") unless kind == "receipt"
      end
      list_page("#{t("title")} #{year}", table, liberal_crumbs, "ui.liberal.#{kind || "journal"}.csv_name", actions,
        tabs: year_tabs(list_url, year), tabs_label: I18n.t("ui.liberal.year"), intro: t("intro"))
    end

    private def columns : Array(Table::Column)
      list = [
        Table::Column.new("date", I18n.t("ui.liberal.columns.date"), "mono"),
        Table::Column.new("number", I18n.t("ui.liberal.columns.number"), "mono", secondary: true),
      ]
      list << Table::Column.new("kind", I18n.t("ui.liberal.columns.kind")) if kind.nil?
      list + [
        Table::Column.new("party", I18n.t("ui.liberal.columns.party")),
        Table::Column.new("heading", I18n.t("ui.liberal.columns.heading"), secondary: true),
        Table::Column.new("method", I18n.t("ui.liberal.columns.method"), secondary: true),
        Table::Column.new("amount", I18n.t("ui.liberal.columns.amount"), "amount"),
      ]
    end

    private def row(item : Liberal::LineView) : Table::Row
      state = if item.reversal?
                I18n.t("ui.liberal.line.reversal")
              elsif item.reversed_by_id
                I18n.t("ui.liberal.line.cancelled")
              end
      cells = [
        Table::Cell.new(fmt.date(item.date), reverse("liberal:line", id: item.id), sort: date_key(item.date), csv: date_key(item.date)),
        Table::Cell.new(item.number),
      ]
      cells << Table::Cell.new(I18n.t("ui.liberal.kinds.#{item.kind}")) if kind.nil?
      cells.concat([
        Table::Cell.new(party(item.party_name, item.card_id).presence || item.label, tag: state),
        Table::Cell.new(item.nature_label),
        Table::Cell.new(method_label(item.method)),
        Table::Cell.new(signed(item), sort: item.cash_flow, csv: fmt.csv_amount(item.cash_flow)),
      ])
      Table::Row.new(cells, item.reversed_by_id || item.reversal? ? "pd-row-closed" : "")
    end

    # Montant présenté : dans le livre-journal complet, une dépense est
    # précédée du signe moins ; dans les listes d'un seul sens, tel quel.
    private def signed(item : Liberal::LineView) : String
      kind.nil? && !item.receipt? ? "−#{euros(item.amount)}" : euros(item.amount)
    end

    private def footers(year : Int32, summary : Liberal::TotalsView) : Array(Table::Row)
      list = [] of Table::Row
      case kind
      when "receipt"
        list << footer(t("total"), summary.receipts, "pd-class")
      when "expense"
        list << footer(t("total"), summary.expenses, "pd-class")
      else
        list << footer(I18n.t("ui.liberal.journal.total_receipts"), summary.receipts, "pd-class")
        list << footer(I18n.t("ui.liberal.journal.total_expenses"), summary.expenses, "pd-class")
        list << footer(I18n.t("ui.liberal.journal.balance"), summary.balance, "pd-class")
      end
      Liberal.heading_totals(current.actor, year).each do |item|
        next unless kind.nil? || item.kind == kind
        next if item.amount.zero?
        list << footer(I18n.t("ui.liberal.recap.heading", heading: heading_label(item.heading)), item.amount)
      end
      list
    end

    private def footer(label : String, total : BigDecimal, css : String = "") : Table::Row
      blanks = columns.size - 2
      Table::Row.new([Table::Cell.new(label)] + Array.new(blanks) { Table::Cell.new("") } +
                     [Table::Cell.new(euros(total), sort: total, csv: fmt.csv_amount(total))], css)
    end
  end

  class LiberalJournalHandler < JournalListHandler
    include WholeJournal
  end

  class LiberalReceiptsHandler < JournalListHandler
    include ReceiptJournal
  end

  class LiberalExpensesHandler < JournalListHandler
    include ExpenseJournal
  end

  # Saisie d'une recette ou d'une dépense, en quelques champs : montant,
  # date (du jour par défaut), rubrique (nature), mode de règlement, client
  # ou fournisseur ; désignation, pièce et part privée (dépense) sous
  # « Plus de détails » ; photo du justificatif visible d'emblée.
  abstract class JournalNewHandler < JournalScreen
    FIELDS = %w[amount date nature_id method party_name label reference nondeductible_amount attachment_id]

    def get
      require!(MODULE, WRITE)
      values = {"date" => today.to_s("%Y-%m-%d"), "method" => kind == "receipt" ? "transfer" : "card"}
      show(build_form(values))
    end

    def post
      require!(MODULE, WRITE)
      values = FIELDS.to_h { |name| {name, field(name)} }
      form = build_form(values)
      upload(form, values)
      input = read(form, values)
      return show(copy_errors(form, build_form(values)), 422) if input.nil?
      result = kind == "receipt" ? Liberal.record_receipt(current.actor, input) : Liberal.record_expense(current.actor, input)
      if created = result.value?
        flash["success"] = t("recorded", {"number" => created.number, "amount" => euros(created.amount)})
        return go(field("again") == "1" ? new_url(kind || "receipt") : list_url)
      end
      show(build_form(values).add_errors(result.errors, fmt), 422)
    end

    private def read(form : Form, values : Hash(String, String)) : Liberal::LineInput?
      amount = fmt.parse_decimal(values["amount"])
      form.add_error("amount", I18n.t(values["amount"].empty? ? "ui.forms.required" : "ui.forms.invalid_number")) unless amount
      date = fmt.parse_date(values["date"])
      form.add_error("date", I18n.t("ui.forms.invalid_date")) unless date
      nature_id = values["nature_id"].to_i64?
      form.add_error("nature_id", I18n.t("ui.forms.required")) unless nature_id
      private_part = BigDecimal.new(0)
      unless values["nondeductible_amount"].empty?
        private_part = fmt.parse_decimal(values["nondeductible_amount"]) || begin
          form.add_error("nondeductible_amount", I18n.t("ui.forms.invalid_number"))
          BigDecimal.new(0)
        end
      end
      return if form.invalid || amount.nil? || date.nil? || nature_id.nil?
      Liberal::LineInput.new(date: date, nature_id: nature_id, amount: amount, method: values["method"],
        party_name: values["party_name"], label: values["label"], reference: values["reference"],
        attachment_id: values["attachment_id"].to_i64?, nondeductible_amount: private_part)
    end

    private def build_form(values : Hash(String, String)) : Form
      Form.new([Form::Group.new(nil, main_fields(values)), Form::Group.new(I18n.t("ui.liberal.fields.more"), more_fields(values))])
    end

    # Rubrique proposée : celle saisie, sinon (recette) la nature des
    # paramètres, sinon la première.
    private def nature_value(values : Hash(String, String), natures : Array(Liberal::NatureView)) : String
      chosen = values["nature_id"]?.presence
      chosen ||= Liberal.settings(current.actor).default_nature_id.try(&.to_s) if kind == "receipt"
      chosen || natures.first?.try(&.id.to_s) || ""
    end

    # Natures du sens, rubriques de la 2035 d'abord, celles hors 2035
    # (apports, emprunts, prélèvements) ensuite.
    private def natures : Array(Liberal::NatureView)
      list = Liberal.natures(current.actor, kind, enabled_only: true)
      list.sort_by { |item| {item.excluded? ? 1 : 0, Liberal::HEADINGS.index(item.heading) || 0, item.label} }
    end

    private def main_fields(values : Hash(String, String)) : Array(Form::Field)
      choices = natures
      [
        Form::Field.new("amount", t("amount_field"), "number", values["amount"]? || "", required: true, mono: true,
          placeholder: "0,00", help: t("amount_help")),
        Form::Field.new("date", t("date_field"), "date", values["date"]? || "", required: true),
        Form::Field.new("nature_id", I18n.t("ui.liberal.fields.heading"), "select", nature_value(values, choices), required: true,
          options: choices.map { |item| option(item.id.to_s, item.label) }, help: t("heading_help")),
        Form::Field.new("method", I18n.t("ui.liberal.columns.method"), "select", values["method"]? || "", required: true,
          options: method_options),
        Form::Field.new("party_name", t("party"), value: values["party_name"]? || "", maxlength: 255),
      ]
    end

    private def more_fields(values : Hash(String, String)) : Array(Form::Field)
      more = [
        Form::Field.new("label", I18n.t("ui.liberal.fields.label"), value: values["label"]? || "", maxlength: 255,
          help: t("label_help")),
        Form::Field.new("reference", I18n.t("ui.liberal.fields.reference"), value: values["reference"]? || "", maxlength: 100,
          help: I18n.t("ui.liberal.fields.reference_help")),
      ]
      if kind == "expense"
        more << Form::Field.new("nondeductible_amount", I18n.t("ui.liberal.fields.nondeductible"), "number",
          values["nondeductible_amount"]? || "", mono: true, help: I18n.t("ui.liberal.fields.nondeductible_help"))
      end
      more << Form::Field.new("attachment_id", "", "hidden", values["attachment_id"]? || "")
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      entry_page(t("new"), list_crumbs, form, new_url(kind || "receipt"), list_url, status: status)
    end
  end

  class LiberalReceiptNewHandler < JournalNewHandler
    include ReceiptJournal
  end

  class LiberalExpenseNewHandler < JournalNewHandler
    include ExpenseJournal
  end

  # Consultation d'une ligne ; annulation (contre-passation datée du jour)
  # tant qu'elle n'est ni annulée ni elle-même une annulation.
  class LiberalLineHandler < LiberalScreen
    def get
      item = Liberal.line(current.actor, id_param)
      prefix = "ui.liberal.#{item.kind}"
      details = [
        Screen::Item.new(I18n.t("ui.liberal.columns.number"), item.number, mono: true),
        Screen::Item.new(I18n.t("#{prefix}.date_field"), fmt.date(item.date)),
        Screen::Item.new(I18n.t("ui.liberal.columns.amount"), euros(item.amount)),
        Screen::Item.new(I18n.t("ui.liberal.fields.nondeductible"), item.nondeductible_amount.zero? ? "" : euros(item.nondeductible_amount)),
        Screen::Item.new(I18n.t("#{prefix}.party"), party(item.party_name, item.card_id)),
        Screen::Item.new(I18n.t("ui.liberal.fields.heading"), "#{item.nature_label} · #{heading_label(item.heading)}"),
        Screen::Item.new(I18n.t("ui.liberal.columns.method"), method_label(item.method)),
        Screen::Item.new(I18n.t("ui.liberal.fields.label"), item.label),
        Screen::Item.new(I18n.t("ui.liberal.fields.reference"), item.reference),
        Screen::Item.new(I18n.t("ui.liberal.fields.origin"), I18n.t("ui.liberal.origins.#{item.origin == "manual" ? "manual" : "invoicing"}")),
      ]
      if attachment = item.attachment_id
        details << Screen::Item.new(I18n.t("ui.liberal.fields.attachment"), I18n.t("ui.liberal.fields.attachment_open"),
          reverse("core:attachment", id: attachment))
      end
      item.reversal_of_id.try { |id| details << Screen::Item.new(I18n.t("ui.liberal.line.cancels"), number(id), reverse("liberal:line", id: id), mono: true) }
      item.reversed_by_id.try { |id| details << Screen::Item.new(I18n.t("ui.liberal.line.cancelled_by"), number(id), reverse("liberal:line", id: id), mono: true) }
      actions = [] of Screen::Action
      if can?(WRITE) && !item.reversal? && item.reversed_by_id.nil?
        actions << post_action("ui.liberal.line.cancel", reverse("liberal:line_reverse", id: item.id),
          "ui.liberal.line.cancel_confirm", "danger", "x")
      end
      status = item.reversal? ? I18n.t("ui.liberal.line.reversal") : (item.reversed_by_id ? I18n.t("ui.liberal.line.cancelled") : nil)
      intro = item.locked ? I18n.t("ui.liberal.line.locked") : I18n.t("ui.liberal.line.intangible")
      list = item.receipt? ? reverse("liberal:receipts") : reverse("liberal:expenses")
      crumbs = liberal_crumbs << Screen::Crumb.new(I18n.t("#{prefix}.title"), list)
      detail_page("#{I18n.t("#{prefix}.one")} #{item.number}", crumbs, [Screen::Section.new(I18n.t("#{prefix}.one"), details)],
        actions, status_tag: status, intro: intro)
    end

    private def number(id : Int64) : String
      Liberal.line(current.actor, id).number
    end
  end

  # Annulation d'une ligne : contre-passation datée du jour.
  class LiberalLineReverseHandler < LiberalScreen
    def post
      require!(MODULE, WRITE)
      item = Liberal.line(current.actor, id_param)
      result = Liberal.reverse_line(current.actor, Liberal::ReverseInput.new(item.id, today))
      if reversal = result.value?
        flash["success"] = I18n.t("ui.liberal.line.cancelled_flash", number: item.number, reversal: reversal.number)
      else
        flash["danger"] = messages(result.errors)
      end
      go(reverse("liberal:line", id: item.id))
    end
  end
end
