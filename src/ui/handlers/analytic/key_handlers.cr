# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Clés de répartition (menu `analytic:keys`, successeur de `anc_key.inc.php`
  # et `Anc_Key`) : liste, consultation, création, modification,
  # suppression. Une clé : des lignes (pourcentage, un poste par plan) qui
  # totalisent 100 %, et les journaux où elle est proposée à la saisie.
  abstract class KeyScreen < AnalyticScreen
    WRITE = "analytic.plan.write"

    def crumbs : Array(Screen::Crumb)
      analytic_crumbs("analytic.menu.ana_keys", reverse("analytic:keys"))
    end

    def key_url(id : Int64) : String
      reverse("analytic:key", id: id)
    end

    # Journaux proposés (lisibles de l'acteur).
    def ledgers : Array(Partiduo::Api::Accounting::LedgerView)
      @ledgers ||= Partiduo::Api::Accounting.ledgers(current.actor).reject(&.access.none?)
    rescue Partiduo::Api::AccessDenied
      @ledgers = [] of Partiduo::Api::Accounting::LedgerView
    end

    @ledgers : Array(Partiduo::Api::Accounting::LedgerView)?

    # Ligne de clé affichée : pourcentage saisi et poste choisi par plan.
    record RowValues, percent : String, posts : Hash(Int64, String)

    def key_form(name : String, description : String, rows : Array(RowValues), ledger_ids : Array(Int64)) : Form
      groups = [Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.analytic.key_name"), value: name, required: true, maxlength: 100, wide: true),
        Form::Field.new("description", I18n.t("ui.analytic.description"), "textarea", description, wide: true),
      ])]
      (rows + Array.new(SPARE_ROWS) { RowValues.new("", {} of Int64 => String) }).each_with_index do |row, index|
        fields = [Form::Field.new("rows-#{index}-percent", I18n.t("ui.analytic.percent"), "number", row.percent, mono: true)]
        plans.each { |plan| fields << post_field("rows-#{index}", plan, row.posts[plan.id]? || "") }
        groups << Form::Group.new(I18n.t("ui.analytic.row_number", number: index + 1), fields)
      end
      unless ledgers.empty?
        checks = ledgers.map do |ledger|
          Form::Field.new("ledger-#{ledger.id}", "#{ledger.code} · #{ledger.name}", "checkbox", ledger_ids.includes?(ledger.id) ? "1" : "")
        end
        groups << Form::Group.new(I18n.t("ui.analytic.key_ledgers"), checks)
      end
      Form.new(groups)
    end

    # Lignes relues du formulaire (lignes vides ignorées) et entrée du contrat.
    def read_key(form_errors : Array({String, String})) : {Ana::KeyInput, Array(RowValues)}
      values = [] of RowValues
      inputs = [] of Ana::KeyRowInput
      row_indices("rows").each do |index|
        prefix = "rows-#{index}"
        posts = plans.to_h { |plan| {plan.id, field("#{prefix}-p#{plan.id}")} }.reject { |_, value| value.empty? }
        next if field("#{prefix}-percent").empty? && posts.empty?
        position = values.size
        values << RowValues.new(field("#{prefix}-percent"), posts)
        percent = amount_of("#{prefix}-percent", form_errors) || BigDecimal.new(0)
        # Rangée à sa place dans le formulaire réaffiché (lignes compactées).
        form_errors.map! { |(name, message)| name == "#{prefix}-percent" ? {"rows-#{position}-percent", message} : {name, message} }
        inputs << Ana::KeyRowInput.new(percent, read_post_ids(prefix))
      end
      ledger_ids = ledgers.select { |ledger| checkbox("ledger-#{ledger.id}") }.map(&.id)
      input = Ana::KeyInput.new(name: field("name"), rows: inputs, description: field("description", strip: false).strip,
        ledger_ids: ledger_ids)
      {input, values}
    end

    def rows_of(key : Ana::KeyView) : Array(RowValues)
      key.rows.map { |row| RowValues.new(amount_text(row.percent), selected_posts(row.posts)) }
    end
  end

  class AnalyticKeysHandler < KeyScreen
    def get
      columns = [
        Table::Column.new("name", I18n.t("ui.analytic.key_name")),
        Table::Column.new("description", I18n.t("ui.analytic.description")),
        Table::Column.new("rows", I18n.t("ui.analytic.rows_count"), "amount", secondary: true),
      ]
      rows = Ana.keys(current.actor).map do |key|
        Table::Row.new([
          # Clé incomplète (poste ou plan supprimé, D-ANA-013) : signalée.
          Table::Cell.new(key.complete? ? key.name : I18n.t("ui.analytic.key_incomplete_name", name: key.name), key_url(key.id)),
          Table::Cell.new(key.description),
          Table::Cell.new(key.rows.size.to_s, sort: BigDecimal.new(key.rows.size)),
        ])
      end
      table = Table.new(I18n.t("analytic.menu.ana_keys"), columns, rows, reverse("analytic:keys"),
        empty_message: I18n.t("ui.analytic.no_keys"))
      actions = [] of Screen::Action
      actions << link_action("ui.analytic.new_key", reverse("analytic:key_new"), "primary", "plus") if can?(WRITE)
      list_page(I18n.t("analytic.menu.ana_keys"), table, analytic_crumbs, "ui.analytic.keys_csv", actions,
        intro: I18n.t("ui.analytic.keys_intro"))
    end
  end

  class AnalyticKeyNewHandler < KeyScreen
    def get
      require!(MODULE, WRITE)
      show(key_form("", "", [RowValues.new("100", {} of Int64 => String)], [] of Int64))
    end

    def post
      form_errors = [] of {String, String}
      input, values = read_key(form_errors)
      form = key_form(input.name, input.description, values, input.ledger_ids)
      unless form_errors.empty?
        form_errors.each { |(name, message)| form.add_error(name, message) }
        return show(form)
      end
      result = Ana.create_key(current.actor, input)
      if key = result.value?
        flash["success"] = I18n.t("ui.analytic.key_created", name: key.name)
        return go(key_url(key.id))
      end
      show(add_contract_errors(form, result.errors))
    end

    private def show(form : Form)
      intro = no_plan? ? I18n.t("ui.analytic.no_plans") : nil
      form_page(I18n.t("ui.analytic.new_key"), crumbs, form, reverse("analytic:key_new"), I18n.t("ui.forms.create"),
        reverse("analytic:keys"), intro: intro)
    end
  end

  class AnalyticKeyHandler < KeyScreen
    def get
      key = Ana.key(current.actor, id_param)
      actions = [] of Screen::Action
      if can?(WRITE)
        actions << link_action("ui.forms.edit", reverse("analytic:key_edit", id: key.id), "primary")
        actions << post_action("ui.forms.delete", reverse("analytic:key_delete", id: key.id), "ui.analytic.key_delete_confirm", "danger")
      end
      names = ledgers.select { |ledger| key.ledger_ids.includes?(ledger.id) }.map { |ledger| "#{ledger.code} · #{ledger.name}" }
      items = [
        Screen::Item.new(I18n.t("ui.analytic.key_name"), key.complete? ? key.name : I18n.t("ui.analytic.key_incomplete_name", name: key.name)),
        Screen::Item.new(I18n.t("ui.analytic.description"), key.description),
        Screen::Item.new(I18n.t("ui.analytic.key_ledgers"), names.join(", ")),
        Screen::Item.new(I18n.t("ui.analytic.total_percent"), "#{amount_text(key.total_percent)} %", mono: true),
      ]
      detail_page(I18n.t("ui.analytic.key_title", name: key.name), crumbs,
        [Screen::Section.new(I18n.t("ui.analytic.summary"), items),
         Screen::Section.new(I18n.t("ui.analytic.key_rows"), table: rows_table(key))], actions)
    end

    private def rows_table(key : Ana::KeyView) : Table
      columns = [Table::Column.new("percent", I18n.t("ui.analytic.percent"), "amount")] +
                plans.map { |plan| Table::Column.new("p#{plan.id}", plan.name, "mono") }
      rows = key.rows.map do |row|
        cells = [Table::Cell.new(amount_text(row.percent), sort: row.percent)]
        plans.each do |plan|
          post = row.posts.find(&.plan_id.==(plan.id))
          cells << Table::Cell.new(post.try(&.code) || "", post.try { |item| post_url(item.id) })
        end
        Table::Row.new(cells)
      end
      table = Table.new(I18n.t("ui.analytic.key_rows"), columns, rows, key_url(key.id), id: "pd-key-rows")
      table.exportable = false
      table
    end
  end

  class AnalyticKeyEditHandler < KeyScreen
    def get
      require!(MODULE, WRITE)
      key = Ana.key(current.actor, id_param)
      show(key, key_form(key.name, key.description, rows_of(key), key.ledger_ids))
    end

    def post
      key = Ana.key(current.actor, id_param)
      form_errors = [] of {String, String}
      input, values = read_key(form_errors)
      form = key_form(input.name, input.description, values, input.ledger_ids)
      unless form_errors.empty?
        form_errors.each { |(name, message)| form.add_error(name, message) }
        return show(key, form)
      end
      result = Ana.update_key(current.actor, key.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.analytic.key_updated", name: updated.name)
        return go(key_url(updated.id))
      end
      show(key, add_contract_errors(form, result.errors))
    end

    private def show(key : Ana::KeyView, form : Form)
      form_page(I18n.t("ui.analytic.key_edit", name: key.name), crumbs, form, reverse("analytic:key_edit", id: key.id),
        I18n.t("ui.forms.save"), key_url(key.id))
    end
  end

  class AnalyticKeyDeleteHandler < KeyScreen
    def post
      key = Ana.key(current.actor, id_param)
      result = Ana.delete_key(current.actor, key.id)
      if result.success?
        flash["success"] = I18n.t("ui.analytic.key_deleted", name: key.name)
        go(reverse("analytic:keys"))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(key_url(key.id))
      end
    end
  end
end
