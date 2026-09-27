# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Opérations diverses analytiques (menu `analytic:misc_operations`,
  # successeur de `anc_od.inc.php` et `Anc_Group_Operation`) : imputations
  # sans écriture comptable, équilibrées dans chaque plan. Liste par
  # période, consultation, création, modification, suppression.
  abstract class MiscScreen < AnalyticScreen
    WRITE = "analytic.operation.write"

    def crumbs : Array(Screen::Crumb)
      analytic_crumbs("analytic.menu.ana_misc", reverse("analytic:misc_operations"))
    end

    def misc_url(id : Int64) : String
      reverse("analytic:misc_operation", id: id)
    end

    record RowValues, amount : String, side : String, card : String, posts : Hash(Int64, String)

    def blank_row : RowValues
      RowValues.new("", "debit", "", {} of Int64 => String)
    end

    def misc_form(date : String, description : String, rows : Array(RowValues)) : Form
      groups = [Form::Group.new(nil, [
        Form::Field.new("date", I18n.t("ui.analytic.date"), value: date, required: true, mono: true),
        Form::Field.new("description", I18n.t("ui.analytic.description"), value: description, required: true, wide: true),
      ])]
      sides = [option("debit", I18n.t("ui.analytic.debit")), option("credit", I18n.t("ui.analytic.credit"))]
      (rows + Array.new(SPARE_ROWS) { blank_row }).each_with_index do |row, index|
        prefix = "rows-#{index}"
        fields = [
          Form::Field.new("#{prefix}-amount", I18n.t("ui.analytic.amount"), "number", row.amount, mono: true),
          Form::Field.new("#{prefix}-side", I18n.t("ui.analytic.side"), "select", row.side, options: sides),
          Form::Field.new("#{prefix}-card", I18n.t("ui.analytic.card"), value: row.card, mono: true),
        ]
        plans.each { |plan| fields << post_field(prefix, plan, row.posts[plan.id]? || "") }
        groups << Form::Group.new(I18n.t("ui.analytic.row_number", number: index + 1), fields)
      end
      Form.new(groups)
    end

    # Opération relue : entrée du contrat (`nil` si un champ est illisible)
    # et valeurs à réafficher.
    def read_misc(form_errors : Array({String, String})) : {Ana::MiscOperationInput?, Array(RowValues)}
      values = [] of RowValues
      inputs = [] of Ana::MiscRowInput
      row_indices("rows").each do |index|
        prefix = "rows-#{index}"
        posts = plans.to_h { |plan| {plan.id, field("#{prefix}-p#{plan.id}")} }.reject { |_, value| value.empty? }
        next if field("#{prefix}-amount").empty? && posts.empty? && field("#{prefix}-card").empty?
        position = values.size
        side = field("#{prefix}-side") == "credit" ? "credit" : "debit"
        values << RowValues.new(field("#{prefix}-amount"), side, field("#{prefix}-card"), posts)
        errors = [] of {String, String}
        amount = amount_of("#{prefix}-amount", errors) || BigDecimal.new(0)
        errors.each { |(_, message)| form_errors << {"rows-#{position}-amount", message} }
        inputs << Ana::MiscRowInput.new(amount, side == "credit" ? Ana::Side::Credit : Ana::Side::Debit,
          read_post_ids(prefix), field("#{prefix}-card").presence)
      end
      day = fmt.parse_short_date(field("date"), Partiduo::Api::Core.today)
      form_errors << {"date", I18n.t("ui.forms.invalid_date")} unless day
      return {nil, values} unless day && form_errors.empty?
      {Ana::MiscOperationInput.new(date: day, description: field("description"), rows: inputs), values}
    end

    def rows_of(operation : Ana::DistributionView) : Array(RowValues)
      operation.rows.map do |row|
        RowValues.new(amount_text(row.amount), row.side.credit? ? "credit" : "debit", row.card_code || "", selected_posts(row.posts))
      end
    end

    def refused(values : Array(RowValues), form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = misc_form(field("date"), field("description"), values)
      form_errors.each { |(name, message)| form.add_error(name, message) }
      add_contract_errors(form, errors)
    end
  end

  class AnalyticMiscOperationsHandler < MiscScreen
    def get
      from = query("from").presence.try { |text| fmt.parse_short_date(text, Partiduo::Api::Core.today) }
      to = query("to").presence.try { |text| fmt.parse_short_date(text, Partiduo::Api::Core.today) }
      operations = Ana.misc_operations(current.actor, from, to)
      columns = [
        Table::Column.new("date", I18n.t("ui.analytic.date"), "mono"),
        Table::Column.new("description", I18n.t("ui.analytic.description")),
        Table::Column.new("rows", I18n.t("ui.analytic.rows_count"), "amount", secondary: true),
      ]
      rows = operations.map do |operation|
        Table::Row.new([
          Table::Cell.new(fmt.date(operation.date), misc_url(operation.id), sort: date_key(operation.date)),
          Table::Cell.new(operation.description, misc_url(operation.id)),
          Table::Cell.new(operation.rows.size.to_s, sort: BigDecimal.new(operation.rows.size)),
        ])
      end
      params = {} of String => String
      params["from"] = query("from") unless query("from").empty?
      params["to"] = query("to") unless query("to").empty?
      table = Table.new(I18n.t("analytic.menu.ana_misc"), columns, rows, reverse("analytic:misc_operations"), params,
        empty_message: I18n.t("ui.analytic.no_misc"))
      actions = [] of Screen::Action
      actions << link_action("ui.analytic.new_misc", reverse("analytic:misc_new"), "primary", "plus") if can?(WRITE)
      filters = search_filters([
        Form::Field.new("from", I18n.t("ui.accounts.from"), value: query("from"), mono: true),
        Form::Field.new("to", I18n.t("ui.accounts.to"), value: query("to"), mono: true),
      ])
      list_page(I18n.t("analytic.menu.ana_misc"), table, analytic_crumbs, "ui.analytic.misc_csv", actions,
        filters: filters, intro: I18n.t("ui.analytic.misc_intro"))
    end
  end

  class AnalyticMiscNewHandler < MiscScreen
    def get
      require!(MODULE, WRITE)
      show(misc_form(fmt.date(Partiduo::Api::Core.today), "", [blank_row, RowValues.new("", "credit", "", {} of Int64 => String)]))
    end

    def post
      form_errors = [] of {String, String}
      input, values = read_misc(form_errors)
      return show(refused(values, form_errors)) unless input
      result = Ana.create_misc_operation(current.actor, input)
      if operation = result.value?
        flash["success"] = I18n.t("ui.analytic.misc_created")
        return go(misc_url(operation.id))
      end
      show(refused(values, form_errors, result.errors))
    end

    private def show(form : Form)
      intro = no_plan? ? I18n.t("ui.analytic.no_plans") : I18n.t("ui.analytic.misc_help")
      form_page(I18n.t("ui.analytic.new_misc"), crumbs, form, reverse("analytic:misc_new"), I18n.t("ui.forms.create"),
        reverse("analytic:misc_operations"), intro: intro)
    end
  end

  class AnalyticMiscHandler < MiscScreen
    def get
      operation = Ana.misc_operation(current.actor, id_param)
      actions = [] of Screen::Action
      if can?(WRITE)
        actions << link_action("ui.forms.edit", reverse("analytic:misc_edit", id: operation.id), "primary")
        actions << post_action("ui.forms.delete", reverse("analytic:misc_delete", id: operation.id), "ui.analytic.misc_delete_confirm", "danger")
      end
      items = [
        Screen::Item.new(I18n.t("ui.analytic.date"), fmt.date(operation.date), mono: true),
        Screen::Item.new(I18n.t("ui.analytic.description"), operation.description),
      ]
      detail_page(I18n.t("ui.analytic.misc_title", date: fmt.date(operation.date)), crumbs,
        [Screen::Section.new(I18n.t("ui.analytic.summary"), items),
         Screen::Section.new(I18n.t("ui.analytic.rows"), table: rows_table(operation))], actions)
    end

    private def rows_table(operation : Ana::DistributionView) : Table
      columns = [
        Table::Column.new("debit", I18n.t("ui.analytic.debit"), "amount"),
        Table::Column.new("credit", I18n.t("ui.analytic.credit"), "amount"),
        Table::Column.new("card", I18n.t("ui.analytic.card"), "mono", secondary: true),
      ] + plans.map { |plan| Table::Column.new("p#{plan.id}", plan.name, "mono") }
      rows = operation.rows.map do |row|
        cells = [
          Table::Cell.new(row.side.debit? ? fmt.amount(row.amount) : "", sort: row.side.debit? ? row.amount : BigDecimal.new(0)),
          Table::Cell.new(row.side.credit? ? fmt.amount(row.amount) : "", sort: row.side.credit? ? row.amount : BigDecimal.new(0)),
          Table::Cell.new(row.card_code || ""),
        ]
        plans.each do |plan|
          post = row.posts.find(&.plan_id.==(plan.id))
          cells << Table::Cell.new(post.try(&.code) || "", post.try { |item| post_url(item.id) })
        end
        Table::Row.new(cells)
      end
      table = Table.new(I18n.t("ui.analytic.rows"), columns, rows, misc_url(operation.id), id: "pd-misc-rows")
      table.exportable = false
      table
    end
  end

  class AnalyticMiscEditHandler < MiscScreen
    def get
      require!(MODULE, WRITE)
      operation = Ana.misc_operation(current.actor, id_param)
      show(operation, misc_form(fmt.date(operation.date), operation.description, rows_of(operation)))
    end

    def post
      operation = Ana.misc_operation(current.actor, id_param)
      form_errors = [] of {String, String}
      input, values = read_misc(form_errors)
      return show(operation, refused(values, form_errors)) unless input
      result = Ana.update_misc_operation(current.actor, operation.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.analytic.misc_updated")
        return go(misc_url(updated.id))
      end
      show(operation, refused(values, form_errors, result.errors))
    end

    private def show(operation : Ana::DistributionView, form : Form)
      form_page(I18n.t("ui.analytic.misc_edit"), crumbs, form, reverse("analytic:misc_edit", id: operation.id),
        I18n.t("ui.forms.save"), misc_url(operation.id), intro: I18n.t("ui.analytic.misc_help"))
    end
  end

  class AnalyticMiscDeleteHandler < MiscScreen
    def post
      operation = Ana.misc_operation(current.actor, id_param)
      result = Ana.delete_misc_operation(current.actor, operation.id)
      if result.success?
        flash["success"] = I18n.t("ui.analytic.misc_deleted")
        go(reverse("analytic:misc_operations"))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(misc_url(operation.id))
      end
    end
  end
end
