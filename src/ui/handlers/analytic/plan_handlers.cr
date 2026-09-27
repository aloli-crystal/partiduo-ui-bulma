# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Plans analytiques, groupes et postes (menu `analytic:plans`, successeur
  # de `anc_pa.inc.php`, `Anc_Account_Table`, `anc_group.inc.php`) : liste
  # des plans, consultation d'un plan (postes et groupes), création,
  # modification, suppression ; paramètres (`analytic:settings`).
  abstract class PlanScreen < AnalyticScreen
    WRITE = "analytic.plan.write"

    def crumbs : Array(Screen::Crumb)
      analytic_crumbs("analytic.menu.ana_plans", reverse("analytic:plans"))
    end

    def plan_crumbs(plan : Ana::PlanView) : Array(Screen::Crumb)
      crumbs << Screen::Crumb.new(plan.name, plan_url(plan.id))
    end

    def plan_form(name = "", description = "") : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.analytic.plan_name"), value: name, required: true, mono: true, maxlength: 100,
          help: I18n.t("ui.analytic.plan_name_help")),
        Form::Field.new("description", I18n.t("ui.analytic.description"), "textarea", description, wide: true),
      ])])
    end

    def plan_input : Ana::PlanInput
      Ana::PlanInput.new(name: field("name"), description: field("description", strip: false).strip)
    end

    def group_options(plan_id : Int64, selected : String) : Array(Form::Option)
      [option("", I18n.t("ui.analytic.no_group"))] +
        Ana.groups(current.actor, plan_id).map { |group| option(group.id.to_s, group.description.empty? ? group.code : "#{group.code} · #{group.description}") }
    end

    def post_form(plan_id : Int64, code = "", description = "", group = "", active = true) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("code", I18n.t("ui.analytic.post_code"), value: code, required: true, mono: true, maxlength: 100,
          help: I18n.t("ui.analytic.post_code_help")),
        Form::Field.new("description", I18n.t("ui.analytic.description"), value: description, wide: true),
        Form::Field.new("group_id", I18n.t("ui.analytic.group"), "select", group, options: group_options(plan_id, group)),
        Form::Field.new("active", I18n.t("ui.analytic.active"), "checkbox", active ? "1" : ""),
      ])])
    end

    def post_input(plan_id : Int64) : Ana::PostInput
      Ana::PostInput.new(plan_id: plan_id, code: field("code"), description: field("description"),
        group_id: field("group_id").to_i64?, active: checkbox("active"))
    end

    def group_form(code = "", description = "") : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("code", I18n.t("ui.analytic.group_code"), value: code, required: true, mono: true, maxlength: 10,
          help: I18n.t("ui.analytic.group_code_help")),
        Form::Field.new("description", I18n.t("ui.analytic.description"), value: description, wide: true),
      ])])
    end

    def group_input(plan_id : Int64) : Ana::GroupInput
      Ana::GroupInput.new(plan_id: plan_id, code: field("code"), description: field("description"))
    end
  end

  class AnalyticPlansHandler < PlanScreen
    def get
      columns = [
        Table::Column.new("name", I18n.t("ui.analytic.plan_name"), "mono"),
        Table::Column.new("description", I18n.t("ui.analytic.description")),
        Table::Column.new("posts", I18n.t("ui.analytic.posts_count"), "amount"),
        Table::Column.new("groups", I18n.t("ui.analytic.groups_count"), "amount", secondary: true),
      ]
      rows = plans.map do |plan|
        Table::Row.new([
          Table::Cell.new(plan.name, plan_url(plan.id)),
          Table::Cell.new(plan.description),
          Table::Cell.new(plan.posts_count.to_s, sort: BigDecimal.new(plan.posts_count)),
          Table::Cell.new(plan.groups_count.to_s, sort: BigDecimal.new(plan.groups_count)),
        ])
      end
      table = Table.new(I18n.t("analytic.menu.ana_plans"), columns, rows, reverse("analytic:plans"),
        empty_message: I18n.t("ui.analytic.no_plans"))
      actions = [] of Screen::Action
      if can?(WRITE)
        actions << link_action("ui.analytic.new_plan", reverse("analytic:plan_new"), "primary", "plus")
        actions << link_action("analytic.menu.ana_settings", reverse("analytic:settings"), icon: "settings")
      end
      list_page(I18n.t("analytic.menu.ana_plans"), table, analytic_crumbs, "ui.analytic.plans_csv", actions,
        intro: I18n.t("ui.analytic.plans_intro"))
    end
  end

  class AnalyticPlanNewHandler < PlanScreen
    def get
      require!(MODULE, WRITE)
      show(plan_form)
    end

    def post
      input = plan_input
      result = Ana.create_plan(current.actor, input)
      if plan = result.value?
        flash["success"] = I18n.t("ui.analytic.plan_created", name: plan.name)
        return go(plan_url(plan.id))
      end
      show(add_contract_errors(plan_form(input.name, input.description), result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.analytic.new_plan"), crumbs, form, reverse("analytic:plan_new"), I18n.t("ui.forms.create"),
        reverse("analytic:plans"))
    end
  end

  class AnalyticPlanHandler < PlanScreen
    def get
      plan = Ana.plan(current.actor, id_param)
      writer = can?(WRITE)
      actions = [] of Screen::Action
      if writer
        actions << link_action("ui.analytic.new_post", reverse("analytic:post_new", plan_id: plan.id), "primary", "plus")
        actions << link_action("ui.analytic.new_group", reverse("analytic:group_new", plan_id: plan.id), icon: "plus")
        actions << link_action("ui.forms.edit", reverse("analytic:plan_edit", id: plan.id))
        actions << post_action("ui.forms.delete", reverse("analytic:plan_delete", id: plan.id), "ui.analytic.plan_delete_confirm", "danger")
      end
      items = [
        Screen::Item.new(I18n.t("ui.analytic.plan_name"), plan.name, mono: true),
        Screen::Item.new(I18n.t("ui.analytic.description"), plan.description),
      ]
      detail_page(I18n.t("ui.analytic.plan_title", name: plan.name), crumbs,
        [Screen::Section.new(I18n.t("ui.analytic.summary"), items),
         Screen::Section.new(I18n.t("ui.analytic.posts"), table: posts_table(plan, writer)),
         Screen::Section.new(I18n.t("ui.analytic.groups"), table: groups_table(plan, writer))], actions)
    end

    private def posts_table(plan : Ana::PlanView, writer : Bool) : Table
      columns = [
        Table::Column.new("code", I18n.t("ui.analytic.post_code"), "mono"),
        Table::Column.new("description", I18n.t("ui.analytic.description")),
        Table::Column.new("group", I18n.t("ui.analytic.group"), "mono", secondary: true),
        Table::Column.new("operations", I18n.t("ui.analytic.operations_count"), "amount", secondary: true),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status")),
      ]
      rows = Ana.posts(current.actor, plan.id).map do |post|
        Table::Row.new([
          Table::Cell.new(post.code, post_url(post.id)),
          Table::Cell.new(post.description),
          Table::Cell.new(post.group_code || ""),
          Table::Cell.new(post.operations_count.to_s, sort: BigDecimal.new(post.operations_count)),
          Table::Cell.new(I18n.t(post.active ? "ui.analytic.active" : "ui.analytic.inactive")),
        ], post.active ? "" : "pd-row-closed")
      end
      table = Table.new(I18n.t("ui.analytic.posts"), columns, rows, plan_url(plan.id),
        empty_message: I18n.t("ui.analytic.no_posts"), id: "pd-analytic-posts")
      table.exportable = false
      table
    end

    private def groups_table(plan : Ana::PlanView, writer : Bool) : Table
      columns = [
        Table::Column.new("code", I18n.t("ui.analytic.group_code"), "mono"),
        Table::Column.new("description", I18n.t("ui.analytic.description")),
        Table::Column.new("posts", I18n.t("ui.analytic.posts_count"), "amount"),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), sortable: false),
      ]
      rows = Ana.groups(current.actor, plan.id).map do |group|
        actions = [] of Screen::Action
        if writer
          actions << link_action("ui.forms.edit", reverse("analytic:group_edit", id: group.id), "small")
          actions << post_action("ui.forms.delete", reverse("analytic:group_delete", id: group.id), "ui.analytic.group_delete_confirm", "small")
        end
        Table::Row.new([
          Table::Cell.new(group.code),
          Table::Cell.new(group.description),
          Table::Cell.new(group.posts_count.to_s, sort: BigDecimal.new(group.posts_count)),
          Table::Cell.new("", actions: actions),
        ])
      end
      table = Table.new(I18n.t("ui.analytic.groups"), columns, rows, plan_url(plan.id),
        empty_message: I18n.t("ui.analytic.no_groups"), id: "pd-analytic-groups")
      table.exportable = false
      table
    end
  end

  class AnalyticPlanEditHandler < PlanScreen
    def get
      require!(MODULE, WRITE)
      plan = Ana.plan(current.actor, id_param)
      show(plan, plan_form(plan.name, plan.description))
    end

    def post
      plan = Ana.plan(current.actor, id_param)
      input = plan_input
      result = Ana.update_plan(current.actor, plan.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.analytic.plan_updated", name: updated.name)
        return go(plan_url(updated.id))
      end
      show(plan, add_contract_errors(plan_form(input.name, input.description), result.errors))
    end

    private def show(plan : Ana::PlanView, form : Form)
      form_page(I18n.t("ui.analytic.plan_edit", name: plan.name), plan_crumbs(plan), form,
        reverse("analytic:plan_edit", id: plan.id), I18n.t("ui.forms.save"), plan_url(plan.id))
    end
  end

  class AnalyticPlanDeleteHandler < PlanScreen
    def post
      plan = Ana.plan(current.actor, id_param)
      result = Ana.delete_plan(current.actor, plan.id)
      if result.success?
        flash["success"] = I18n.t("ui.analytic.plan_deleted", name: plan.name)
        go(reverse("analytic:plans"))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(plan_url(plan.id))
      end
    end
  end

  # --- Postes ------------------------------------------------------------------

  class AnalyticPostNewHandler < PlanScreen
    def get
      require!(MODULE, WRITE)
      plan = Ana.plan(current.actor, id_param("plan_id"))
      show(plan, post_form(plan.id))
    end

    def post
      plan = Ana.plan(current.actor, id_param("plan_id"))
      input = post_input(plan.id)
      result = Ana.create_post(current.actor, input)
      if post = result.value?
        flash["success"] = I18n.t("ui.analytic.post_created", code: post.code)
        return go(plan_url(plan.id))
      end
      form = post_form(plan.id, input.code, input.description, input.group_id.try(&.to_s) || "", input.active)
      show(plan, add_contract_errors(form, result.errors))
    end

    private def show(plan : Ana::PlanView, form : Form)
      form_page(I18n.t("ui.analytic.new_post_in", plan: plan.name), plan_crumbs(plan), form,
        reverse("analytic:post_new", plan_id: plan.id), I18n.t("ui.forms.create"), plan_url(plan.id))
    end
  end

  class AnalyticPostHandler < PlanScreen
    def get
      post = Ana.post(current.actor, id_param)
      plan = Ana.plan(current.actor, post.plan_id)
      actions = [] of Screen::Action
      if can?("analytic.report.read")
        params = {"plan" => plan.id.to_s, "post_from" => post.code, "post_to" => post.code, "f" => "1"}
        actions << link_action("ui.analytic.post_ledger", "#{reverse("analytic:ledger")}?#{URI::Params.encode(params)}", icon: "book-open")
      end
      if can?(WRITE)
        actions << link_action("ui.forms.edit", reverse("analytic:post_edit", id: post.id), "primary")
        actions << post_action("ui.forms.delete", reverse("analytic:post_delete", id: post.id), "ui.analytic.post_delete_confirm", "danger")
      end
      items = [
        Screen::Item.new(I18n.t("ui.analytic.plan"), plan.name, plan_url(plan.id), mono: true),
        Screen::Item.new(I18n.t("ui.analytic.post_code"), post.code, mono: true),
        Screen::Item.new(I18n.t("ui.analytic.description"), post.description),
        Screen::Item.new(I18n.t("ui.analytic.group"), post.group_code || "", mono: true),
        Screen::Item.new(I18n.t("ui.analytic.operations_count"), post.operations_count.to_s, mono: true),
      ]
      detail_page(I18n.t("ui.analytic.post_title", code: post.code), plan_crumbs(plan),
        [Screen::Section.new(I18n.t("ui.analytic.summary"), items)], actions,
        status_tag: post.active ? nil : I18n.t("ui.analytic.inactive"))
    end
  end

  class AnalyticPostEditHandler < PlanScreen
    def get
      require!(MODULE, WRITE)
      post = Ana.post(current.actor, id_param)
      show(post, post_form(post.plan_id, post.code, post.description, post.group_id.try(&.to_s) || "", post.active))
    end

    def post
      post = Ana.post(current.actor, id_param)
      input = post_input(post.plan_id)
      result = Ana.update_post(current.actor, post.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.analytic.post_updated", code: updated.code)
        return go(post_url(updated.id))
      end
      form = post_form(post.plan_id, input.code, input.description, input.group_id.try(&.to_s) || "", input.active)
      show(post, add_contract_errors(form, result.errors))
    end

    private def show(post : Ana::PostView, form : Form)
      plan = Ana.plan(current.actor, post.plan_id)
      form_page(I18n.t("ui.analytic.post_edit", code: post.code), plan_crumbs(plan), form,
        reverse("analytic:post_edit", id: post.id), I18n.t("ui.forms.save"), post_url(post.id))
    end
  end

  class AnalyticPostDeleteHandler < PlanScreen
    def post
      post = Ana.post(current.actor, id_param)
      result = Ana.delete_post(current.actor, post.id)
      if result.success?
        flash["success"] = I18n.t("ui.analytic.post_deleted", code: post.code)
        go(plan_url(post.plan_id))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(post_url(post.id))
      end
    end
  end

  # --- Groupes -----------------------------------------------------------------

  class AnalyticGroupNewHandler < PlanScreen
    def get
      require!(MODULE, WRITE)
      plan = Ana.plan(current.actor, id_param("plan_id"))
      show(plan, group_form)
    end

    def post
      plan = Ana.plan(current.actor, id_param("plan_id"))
      input = group_input(plan.id)
      result = Ana.create_group(current.actor, input)
      if group = result.value?
        flash["success"] = I18n.t("ui.analytic.group_created", code: group.code)
        return go(plan_url(plan.id))
      end
      show(plan, add_contract_errors(group_form(input.code, input.description), result.errors))
    end

    private def show(plan : Ana::PlanView, form : Form)
      form_page(I18n.t("ui.analytic.new_group_in", plan: plan.name), plan_crumbs(plan), form,
        reverse("analytic:group_new", plan_id: plan.id), I18n.t("ui.forms.create"), plan_url(plan.id))
    end
  end

  class AnalyticGroupEditHandler < PlanScreen
    def get
      require!(MODULE, WRITE)
      group = Ana.group(current.actor, id_param)
      show(group, group_form(group.code, group.description))
    end

    def post
      group = Ana.group(current.actor, id_param)
      input = group_input(group.plan_id)
      result = Ana.update_group(current.actor, group.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.analytic.group_updated", code: updated.code)
        return go(plan_url(updated.plan_id))
      end
      show(group, add_contract_errors(group_form(input.code, input.description), result.errors))
    end

    private def show(group : Ana::GroupView, form : Form)
      plan = Ana.plan(current.actor, group.plan_id)
      form_page(I18n.t("ui.analytic.group_edit", code: group.code), plan_crumbs(plan), form,
        reverse("analytic:group_edit", id: group.id), I18n.t("ui.forms.save"), plan_url(plan.id))
    end
  end

  class AnalyticGroupDeleteHandler < PlanScreen
    def post
      group = Ana.group(current.actor, id_param)
      result = Ana.delete_group(current.actor, group.id)
      if result.success?
        flash["success"] = I18n.t("ui.analytic.group_deleted", code: group.code)
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(plan_url(group.plan_id))
    end
  end

  # --- Paramètres ----------------------------------------------------------------

  # Paramètres de l'analytique (`MY_ANALYTIC`, `MY_ANC_FILTER`).
  class AnalyticSettingsHandler < PlanScreen
    def get
      require!(MODULE, WRITE)
      settings = Ana.settings(current.actor)
      show(settings_form(settings.mandatory, settings.account_filter))
    end

    def post
      input = Ana::SettingsInput.new(mandatory: field("mode") == "mandatory", account_filter: field("account_filter"))
      result = Ana.update_settings(current.actor, input)
      if result.success?
        flash["success"] = I18n.t("ui.analytic.settings_saved")
        return go(reverse("analytic:settings"))
      end
      show(add_contract_errors(settings_form(input.mandatory, input.account_filter), result.errors))
    end

    private def settings_form(mandatory : Bool, filter : String) : Form
      modes = [option("optional", I18n.t("ui.analytic.mode_optional")), option("mandatory", I18n.t("ui.analytic.mode_mandatory"))]
      Form.new([Form::Group.new(nil, [
        Form::Field.new("mode", I18n.t("ui.analytic.mode"), "select", mandatory ? "mandatory" : "optional", options: modes,
          help: I18n.t("ui.analytic.mode_help")),
        Form::Field.new("account_filter", I18n.t("ui.analytic.account_filter"), value: filter, mono: true,
          help: I18n.t("ui.analytic.account_filter_help")),
      ])])
    end

    private def show(form : Form)
      form_page(I18n.t("analytic.menu.ana_settings"), analytic_crumbs, form, reverse("analytic:settings"),
        I18n.t("ui.forms.save"), reverse("analytic:plans"))
    end
  end
end
