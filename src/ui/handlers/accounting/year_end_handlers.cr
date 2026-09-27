# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Fin d'exercice (menu `accounting:closing`, héritier de
  # `operation_exercice.inc.php`) : l'écriture de clôture des comptes 6 et 7
  # ou l'écriture de réouverture (à-nouveaux) proposée par le cœur, puis
  # passée dans un journal d'opérations diverses (D-UI-053).
  class ClosingHandler < AccountingScreen
    PERMISSION = "accounting.period.close"
    KINDS      = %w[closing opening]

    def get
      require!("ACCOUNTING", PERMISSION)
      show
    end

    def post
      require!("ACCOUNTING", PERMISSION)
      input = Acc::ClosingInput.new(fiscal_year_id: field("fiscal_year").to_i64? || 0_i64,
        ledger_id: field("ledger_id").to_i64? || 0_i64, profit_account: field("profit").presence,
        loss_account: field("loss").presence, label: field("label").presence)
      result = kind == "opening" ? Acc.post_opening_entry(current.actor, input) : Acc.post_closing_entry(current.actor, input)
      if entry = result.value?
        flash["success"] = I18n.t("ui.closing.posted_#{kind}", receipt: entry.receipt || entry.internal_code)
        return go(reverse("accounting:entry", id: entry.id))
      end
      show(result.errors, 422)
    end

    private def kind : String
      value = query("kind").presence || field("kind")
      KINDS.includes?(value) ? value : "closing"
    end

    private def fiscal_years : Array(Partiduo::Api::Core::FiscalYearView)
      Partiduo::Api::Core.fiscal_years(current.actor)
    end

    private def selected_year(years) : Partiduo::Api::Core::FiscalYearView?
      wanted = (query("fiscal_year").presence || field("fiscal_year")).to_i64?
      years.find(&.id.==(wanted)) || working_period.try { |period| years.find(&.id.==(period.fiscal_year_id)) } || years.last?
    end

    private def text(name : String) : String
      query(name).presence || field(name)
    end

    private def show(errors = [] of Partiduo::Api::FieldError, status : Int32 = 200)
      years = fiscal_years
      year = selected_year(years)
      context["title"] = I18n.t("accounting.menu.acc_closing")
      context["crumbs"] = [crumb("core.menu.settings"), crumb("accounting.menu.acc_closing", reverse("accounting:closing"))]
      context["intro"] = I18n.t("ui.closing.intro")
      context["chooser"] = chooser(years, year)
      context["chooser_action"] = reverse("accounting:closing")
      context["chooser_submit"] = I18n.t("ui.closing.propose")
      if year.nil?
        context["note"] = I18n.t("ui.closing.no_fiscal_year")
        return page("ui/accounting/closing.html", status: status)
      end

      proposal = proposal_of(year)
      context["table"] = proposal_table(proposal, year)
      context["notes"] = listed(notes_of(proposal))
      context["result"] = proposal.lines.any?(&.result) ? result_text(proposal) : nil
      if !proposal.posted? && !proposal.lines.empty? && can?("accounting.entry.post")
        set_form(post_form(year, errors), reverse("accounting:closing"), I18n.t("ui.closing.post_#{kind}"))
      elsif !errors.empty?
        context["refused"] = errors.map { |error| fmt.message(error) }
      end
      page("ui/accounting/closing.html", status: status)
    end

    private def chooser(years : Array(Partiduo::Api::Core::FiscalYearView), year : Partiduo::Api::Core::FiscalYearView?) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("fiscal_year", I18n.t("ui.closing.fiscal_year"), "select", year.try(&.id.to_s) || "",
          options: years.map { |item| option(item.id.to_s, item.label) }),
        Form::Field.new("kind", I18n.t("ui.closing.kind"), "select", kind,
          options: KINDS.map { |code| option(code, I18n.t("ui.closing.kinds.#{code}")) }),
        Form::Field.new("profit", I18n.t("ui.closing.profit_account"), value: text("profit"), mono: true,
          help: I18n.t("ui.closing.accounts_help")),
        Form::Field.new("loss", I18n.t("ui.closing.loss_account"), value: text("loss"), mono: true),
      ])])
    end

    private def proposal_of(year : Partiduo::Api::Core::FiscalYearView) : Acc::ClosingProposalView
      if kind == "opening"
        Acc.opening_proposal(current.actor, year.id, text("profit").presence, text("loss").presence)
      else
        Acc.closing_proposal(current.actor, year.id, text("profit").presence, text("loss").presence)
      end
    end

    # Avertissements : écriture déjà passée, pas d'exercice précédent, compte
    # de résultat absent, fiches désactivées.
    private def notes_of(proposal : Acc::ClosingProposalView) : Array(String)
      notes = [] of String
      if posted = proposal.posted_entry_id
        notes << I18n.t("ui.closing.already_posted")
        context["posted_url"] = reverse("accounting:entry", id: posted)
      end
      notes << I18n.t("ui.closing.no_previous") if kind == "opening" && proposal.source_fiscal_year_id.nil?
      if proposal.result_account_missing
        account = proposal.result >= 0 ? proposal.profit_account : proposal.loss_account
        notes << I18n.t("ui.closing.result_account_missing", number: account)
        context["chart_new_url"] = reverse("accounting:account_new") if can?("accounting.account.write")
      end
      notes << I18n.t("ui.closing.disabled_cards") if proposal.lines.any?(&.card_disabled)
      notes
    end

    private def post_form(year : Partiduo::Api::Core::FiscalYearView, errors : Array(Partiduo::Api::FieldError)) : Form
      ledgers = Acc.ledgers(current.actor, Acc::LedgerKind::Misc, enabled_only: true).select(&.access.writable?)
      selected = field("ledger_id").presence || ledgers.first?.try(&.id.to_s) || ""
      Form.new([Form::Group.new(nil, [
        Form::Field.new("ledger_id", I18n.t("ui.closing.ledger"), "select", selected,
          options: ledgers.map { |ledger| option(ledger.id.to_s, "#{ledger.code} — #{ledger.name}") }, required: true),
        Form::Field.new("label", I18n.t("ui.closing.label"), value: field("label"), wide: true,
          placeholder: I18n.t("accounting.closing.#{kind}_label", year: year.label)),
        Form::Field.new("fiscal_year", "", "hidden", year.id.to_s),
        Form::Field.new("kind", "", "hidden", kind),
        Form::Field.new("profit", "", "hidden", text("profit")),
        Form::Field.new("loss", "", "hidden", text("loss")),
      ])]).add_errors(errors, fmt)
    end

    private def result_text(proposal : Acc::ClosingProposalView) : String
      if proposal.result >= 0
        I18n.t("ui.closing.profit", amount: fmt.amount(proposal.result))
      else
        I18n.t("ui.closing.loss", amount: fmt.amount(-proposal.result))
      end
    end

    private def proposal_table(proposal : Acc::ClosingProposalView, year) : Table
      columns = [
        Table::Column.new("account", I18n.t("ui.closing.account"), "mono"),
        Table::Column.new("label", I18n.t("ui.closing.account_label")),
        Table::Column.new("card", I18n.t("ui.closing.card"), secondary: true),
        Table::Column.new("debit", I18n.t("ui.accounts.columns.debit"), "amount"),
        Table::Column.new("credit", I18n.t("ui.accounts.columns.credit"), "amount"),
      ]
      rows = proposal.lines.map do |line|
        amount = fmt.amount(line.amount)
        Table::Row.new([
          Table::Cell.new(line.account, "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => line.account})}"),
          Table::Cell.new(line.account_label, tag: line.result ? I18n.t("ui.closing.result_tag") : nil),
          Table::Cell.new([line.card_code, line.card_name].compact.join(" — ")),
          Table::Cell.new(line.side.debit? ? amount : "", sort: line.side.debit? ? line.amount : BigDecimal.new(0)),
          Table::Cell.new(line.side.credit? ? amount : "", sort: line.side.credit? ? line.amount : BigDecimal.new(0)),
        ], line.result ? "pd-row-total" : "")
      end
      footer = [Table::Row.new([
        Table::Cell.new(""), Table::Cell.new(I18n.t("ui.closing.total")), Table::Cell.new(""),
        Table::Cell.new(fmt.amount(proposal.debit)), Table::Cell.new(fmt.amount(proposal.credit)),
      ])]
      date = proposal.date.try { |day| fmt.date(day) } || ""
      table = Table.new(I18n.t("ui.closing.table_#{proposal.kind}", year: year.label, date: date), columns, rows,
        reverse("accounting:closing"), empty_message: I18n.t("ui.closing.empty"), footer_rows: footer)
      table.exportable = false
      table
    end
  end
end
