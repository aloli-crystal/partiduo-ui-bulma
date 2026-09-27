# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Ventilation d'une écriture enregistrée (successeur de la boîte « Analytique »
  # de la consultation d'une opération, `Anc_Operation::save_update_form`) :
  # une rubrique par ligne d'un compte ventilé (`MY_ANC_FILTER`), des lignes
  # de répartition (montant, un poste par plan) et, si le journal en a, une
  # clé de répartition qui remplace les lignes saisies
  # (`Anc_Key::fill_table`). Montant laissé vide : le reste de la ligne.
  class AnalyticEntryDistributionHandler < AnalyticScreen
    WRITE = "analytic.operation.write"

    record RowValues, amount : String, posts : Hash(Int64, String)

    def get
      require!(MODULE, WRITE)
      entry = Partiduo::Api::Accounting.entry(current.actor, id_param)
      return frozen(entry) if entry.cancelled? || entry.reversal?
      existing = Ana.entry_distributions(current.actor, entry.id).compact_map { |item| item.entry_line_id.try { |id| {id, item} } }.to_h
      values = analytic_lines(entry).map do |line|
        existing[line.id]?.try { |item| item.rows.map { |row| RowValues.new(amount_text(row.amount), selected_posts(row.posts)) } } || [] of RowValues
      end
      show(entry, distribution_form(entry, values, [] of String))
    end

    def post
      require!(MODULE, WRITE)
      entry = Partiduo::Api::Accounting.entry(current.actor, id_param)
      return frozen(entry) if entry.cancelled? || entry.reversal?
      lines = analytic_lines(entry)
      form_errors = [] of {String, String}
      values = [] of Array(RowValues)
      keys = [] of String
      inputs = lines.map_with_index do |line, index|
        rows, shown = read_line(index, line, form_errors)
        values << shown
        keys << ""
        Ana::LineDistributionInput.new(line.id, rows)
      end
      form = distribution_form(entry, values, keys)
      unless form_errors.empty?
        form_errors.each { |(name, message)| form.add_error(name, message) }
        return show(entry, form)
      end
      result = Ana.distribute_entry(current.actor, entry.id, inputs)
      if result.success?
        flash["success"] = I18n.t("ui.analytic.distribution_saved")
        return go(reverse("accounting:entry", id: entry.id))
      end
      show(entry, add_contract_errors(form, result.errors))
    end

    # Écriture annulée ou extourne : la ventilation ne se modifie plus
    # (refus du contrat, D-ANA-014) ; retour à la consultation.
    private def frozen(entry : Partiduo::Api::Accounting::EntryView) : Marten::HTTP::Response
      flash["warning"] = I18n.t("analytic.errors.distribution.cancelled_entry")
      go(reverse("accounting:entry", id: entry.id))
    end

    # Lignes de l'écriture soumises à l'analytique.
    private def analytic_lines(entry : Partiduo::Api::Accounting::EntryView) : Array(Partiduo::Api::Accounting::EntryLineView)
      settings = Ana.settings(current.actor)
      entry.lines.select { |line| settings.analytic_account?(line.account_number) }
    end

    private def keys_for(entry : Partiduo::Api::Accounting::EntryView) : Array(Ana::KeyView)
      @keys ||= Ana.keys_for_ledger(current.actor, entry.ledger_id)
    end

    @keys : Array(Ana::KeyView)?

    # Lignes de répartition d'une ligne d'écriture : clé choisie, sinon
    # lignes saisies (montant vide = reste de la ligne).
    private def read_line(index : Int32, line : Partiduo::Api::Accounting::EntryLineView,
                          form_errors : Array({String, String})) : {Array(Ana::DistributionRowInput), Array(RowValues)}
      prefix = "lines-#{index}"
      if key_id = field("#{prefix}-key").to_i64?
        rows = Ana.apply_key(current.actor, key_id, line.amount)
        shown = rows.map { |row| RowValues.new(amount_text(row.amount), posts_by_id(row.post_ids)) }
        return {rows, shown}
      end
      shown = [] of RowValues
      pending = [] of {BigDecimal?, Array(Int64)}
      row_indices("#{prefix}-rows").each do |row_index|
        row_prefix = "#{prefix}-rows-#{row_index}"
        posts = plans.to_h { |plan| {plan.id, field("#{row_prefix}-p#{plan.id}")} }.reject { |_, value| value.empty? }
        next if field("#{row_prefix}-amount").empty? && posts.empty?
        position = shown.size
        shown << RowValues.new(field("#{row_prefix}-amount"), posts)
        errors = [] of {String, String}
        amount = amount_of("#{row_prefix}-amount", errors, required: false)
        errors.each { |(_, message)| form_errors << {"#{prefix}-rows-#{position}-amount", message} }
        pending << {amount, read_post_ids(row_prefix)}
      end
      given = pending.sum(BigDecimal.new(0)) { |(amount, _)| amount || BigDecimal.new(0) }
      rest = line.amount - given
      rows = pending.map { |(amount, posts)| Ana::DistributionRowInput.new(amount || rest, posts) }
      {rows, shown}
    end

    private def posts_by_id(ids : Array(Int64)) : Hash(Int64, String)
      all = posts_by_plan.values.flatten
      ids.compact_map { |id| all.find(&.id.==(id)) }.to_h { |post| {post.plan_id, post.id.to_s} }
    end

    private def distribution_form(entry : Partiduo::Api::Accounting::EntryView, values : Array(Array(RowValues)),
                                  keys : Array(String)) : Form
      key_options = [option("", I18n.t("ui.analytic.no_key"))] + keys_for(entry).map { |key| option(key.id.to_s, key.name) }
      groups = analytic_lines(entry).map_with_index do |line, index|
        prefix = "lines-#{index}"
        fields = [] of Form::Field
        unless keys_for(entry).empty?
          fields << Form::Field.new("#{prefix}-key", I18n.t("ui.analytic.key"), "select", keys[index]? || "", options: key_options,
            help: I18n.t("ui.analytic.key_help"))
        end
        rows = values[index]? || [] of RowValues
        (rows + Array.new(SPARE_ROWS) { RowValues.new("", {} of Int64 => String) }).each_with_index do |row, row_index|
          row_prefix = "#{prefix}-rows-#{row_index}"
          fields << Form::Field.new("#{row_prefix}-amount", I18n.t("ui.analytic.amount_row", number: row_index + 1), "number",
            row.amount, mono: true, help: row_index.zero? ? I18n.t("ui.analytic.amount_rest_help") : nil)
          plans.each { |plan| fields << post_field(row_prefix, plan, row.posts[plan.id]? || "") }
        end
        side = line.side.debit? ? I18n.t("ui.analytic.debit") : I18n.t("ui.analytic.credit")
        legend = I18n.t("ui.analytic.line_legend", number: line.position + 1, account: line.account_number,
          label: line.label.presence || line.account_label, amount: fmt.amount(line.amount), side: side)
        Form::Group.new(legend, fields)
      end
      Form.new(groups)
    end

    # `lines[2]` (erreur d'ensemble d'une ligne) : sous son premier montant.
    def error_field(path : String) : String
      name = super
      name.matches?(/\Alines-\d+\z/) ? "#{name}-rows-0-amount" : name
    end

    private def show(entry : Partiduo::Api::Accounting::EntryView, form : Form) : Marten::HTTP::Response
      title = I18n.t("ui.analytic.distribution_title", receipt: entry.receipt || entry.internal_code)
      intro = if no_plan?
                I18n.t("ui.analytic.no_plans")
              elsif form.groups.empty?
                I18n.t("ui.analytic.no_analytic_line")
              end
      crumbs = [crumb("core.menu.consult"), crumb("accounting.menu.acc_entries", reverse("accounting:entries")),
                Screen::Crumb.new(entry.receipt || entry.internal_code, reverse("accounting:entry", id: entry.id))]
      form_page(title, crumbs, form.groups.empty? || no_plan? ? nil : form, reverse("analytic:entry_distribution", id: entry.id),
        I18n.t("ui.forms.save"), reverse("accounting:entry", id: entry.id), intro: intro)
    end
  end

  # Rubrique « Analytique » de la consultation d'une écriture : ventilation
  # de chaque ligne, lien vers l'écran de ventilation.
  module AnalyticEntrySection
    alias Ana = Partiduo::Api::Analytic

    def self.build(handler : AccountingScreen, entry : Partiduo::Api::Accounting::EntryView) : Screen::Section?
      return unless handler.module_active?("ANALYTIC")
      return unless handler.can?("analytic.report.read") || handler.can?("analytic.operation.write")
      actor = handler.current.actor
      plans = Ana.plans(actor)
      return if plans.empty?
      distributions = Ana.entry_distributions(actor, entry.id)
      lines = entry.lines.index_by(&.id)
      fmt = handler.fmt
      columns = [
        Table::Column.new("line", I18n.t("ui.entries.account"), "mono"),
        Table::Column.new("amount", I18n.t("ui.analytic.amount"), "amount"),
      ] + plans.map { |plan| Table::Column.new("p#{plan.id}", plan.name, "mono") }
      rows = distributions.flat_map do |distribution|
        line = distribution.entry_line_id.try { |id| lines[id]? }
        distribution.rows.map do |row|
          cells = [
            Table::Cell.new(line ? "#{line.position + 1} · #{line.account_number}" : distribution.account_number),
            Table::Cell.new(fmt.amount(row.amount), sort: row.amount),
          ]
          plans.each do |plan|
            post = row.posts.find(&.plan_id.==(plan.id))
            cells << Table::Cell.new(post.try(&.code) || "", post.try { |item| handler.reverse("analytic:post", id: item.id) })
          end
          Table::Row.new(cells)
        end
      end
      table = Table.new(I18n.t("ui.analytic.distribution"), columns, rows, handler.reverse("accounting:entry", id: entry.id),
        empty_message: I18n.t("ui.analytic.not_distributed"), id: "pd-entry-analytic")
      table.exportable = false
      actions = [] of Screen::Action
      # Écriture annulée ou extourne : ventilation figée (D-ANA-014).
      if handler.can?("analytic.operation.write") && !entry.cancelled? && !entry.reversal?
        actions << Screen::Action.new(I18n.t("ui.analytic.distribute"), handler.reverse("analytic:entry_distribution", id: entry.id),
          "get", "small", "chart-pie")
      end
      Screen::Section.new(I18n.t("ui.analytic.distribution"), table: table, actions: actions)
    rescue Partiduo::Api::AccessDenied
      nil
    end
  end
end
