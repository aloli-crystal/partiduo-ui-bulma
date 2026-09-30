# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Paramétrage de la profession libérale (ADR-007 D6) : profession et début
  # d'activité (identification de la 2035), nature des factures encaissées,
  # interface du dossier pour tous ses utilisateurs (« Recettes et
  # dépenses » ou « Comptabilité », celle-ci seulement avec le module
  # Comptabilité actif, DECISIONS D-UI-076),
  # natures (rubrique de la 2035-A de chaque recette ou dépense), table de
  # correspondance datée par millésime (poste → formulaire, ligne, case),
  # chargement des valeurs par défaut, republication vers la Comptabilité.
  # Toutes les commandes exigent `liberal.settings.write` ; le contrat
  # vérifie de nouveau.
  abstract class LiberalSettingsScreen < LiberalScreen
    def settings_crumbs : Array(Screen::Crumb)
      liberal_crumbs << Screen::Crumb.new(I18n.t("ui.liberal.settings.title"), reverse("liberal:settings"))
    end
  end

  class LiberalSettingsHandler < LiberalSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      settings = Liberal.settings(current.actor)
      show(form({
        "profession"          => settings.profession,
        "activity_started_on" => settings.activity_started_on.try(&.to_s("%Y-%m-%d")) || "",
        "default_nature_id"   => settings.default_nature_id.try(&.to_s) || "",
        "interface"           => settings.interface,
      }))
    end

    def post
      require!(MODULE, SETTINGS)
      values = {"profession" => field("profession"), "activity_started_on" => field("activity_started_on"),
                "default_nature_id" => field("default_nature_id"), "interface" => field("interface")}
      shown = form(values)
      started = values["activity_started_on"].empty? ? nil : fmt.parse_date(values["activity_started_on"])
      shown.add_error("activity_started_on", I18n.t("ui.forms.invalid_date")) if started.nil? && !values["activity_started_on"].empty?
      return show(shown, 422) if shown.invalid
      input = Liberal::SettingsInput.new(profession: values["profession"], activity_started_on: started,
        default_nature_id: values["default_nature_id"].to_i64?, interface: values["interface"].presence)
      result = Liberal.update_settings(current.actor, input)
      if result.success?
        flash["success"] = I18n.t("ui.liberal.settings.saved")
        return go(reverse("liberal:settings"))
      end
      show(shown.add_errors(result.errors, fmt), 422)
    end

    private def form(values : Hash(String, String)) : Form
      natures = [option("", I18n.t("ui.liberal.settings.no_nature"))] +
                Liberal.natures(current.actor, "receipt", enabled_only: true).map { |item| option(item.id.to_s, item.label) }
      interfaces = Liberal.interfaces(current.actor)
      choices = interfaces.map { |code| option(code, I18n.t("ui.liberal.settings.interface_#{code}")) }
      help = interfaces.includes?(Liberal::INTERFACE_ACCOUNTING) ? "interface_help" : "interface_help_inactive"
      Form.new([Form::Group.new(nil, [
        Form::Field.new("profession", I18n.t("ui.liberal.settings.profession"), value: values["profession"], maxlength: 100,
          help: I18n.t("ui.liberal.settings.profession_help")),
        Form::Field.new("activity_started_on", I18n.t("ui.liberal.settings.activity_started_on"), "date", values["activity_started_on"]),
        Form::Field.new("default_nature_id", I18n.t("ui.liberal.settings.default_nature"), "select", values["default_nature_id"],
          options: natures, help: I18n.t("ui.liberal.settings.default_nature_help")),
        Form::Field.new("interface", I18n.t("ui.liberal.settings.interface"), "select", values["interface"],
          options: choices, help: I18n.t("ui.liberal.settings.#{help}")),
      ])])
    end

    private def show(form : Form, status : Int32? = nil) : Marten::HTTP::Response
      actions = [
        link_action("ui.liberal.natures.title", reverse("liberal:natures")),
        link_action("ui.liberal.form_lines.title", reverse("liberal:form_lines")),
        post_action("ui.liberal.defaults.action", reverse("liberal:defaults"), "ui.liberal.defaults.confirm"),
      ]
      if module_active?("ACCOUNTING")
        actions << post_action("ui.liberal.republish.action", reverse("liberal:republish"), "ui.liberal.republish.confirm")
        actions << link_action("ui.liberal.accounts.title", reverse("accounting:liberal_accounts")) if can?("accounting.account.read")
      end
      {"core:company" => {"core.settings.manage", "core.menu.core_company"},
       "core:users"   => {"core.users.manage", "core.menu.core_users"},
       "core:modules" => {"core.modules.manage", "core.menu.core_modules"}}.each do |route, (permission, label)|
        actions << link_action(label, reverse(route)) if can?(permission)
      end
      form_page(I18n.t("ui.liberal.settings.title"), liberal_crumbs, form, reverse("liberal:settings"), I18n.t("ui.forms.save"),
        actions: actions, intro: I18n.t("ui.liberal.settings.intro"), status: status)
    end
  end

  # Natures : liste, création sous la liste. Une nature employée ne change
  # plus que de libellé et d'activation (règle du contrat).
  class LiberalNaturesHandler < LiberalSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      show(LiberalNatureForm.build(self, "", "", "expense", "purchases", true))
    end

    def post
      require!(MODULE, SETTINGS)
      input = LiberalNatureForm.read(self)
      result = Liberal.create_nature(current.actor, input)
      if nature = result.value?
        flash["success"] = I18n.t("ui.liberal.natures.created", code: nature.code)
        return go(reverse("liberal:natures"))
      end
      show(LiberalNatureForm.build(self, input.code, input.label, input.kind, input.heading, input.enabled)
        .add_errors(result.errors, fmt), 422)
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      columns = [
        Table::Column.new("code", I18n.t("ui.liberal.natures.code"), "mono"),
        Table::Column.new("label", I18n.t("ui.liberal.natures.label")),
        Table::Column.new("kind", I18n.t("ui.liberal.columns.kind")),
        Table::Column.new("heading", I18n.t("ui.liberal.fields.heading"), secondary: true),
        Table::Column.new("status", I18n.t("ui.liberal.natures.status"), secondary: true),
      ]
      rows = Liberal.natures(current.actor).map do |nature|
        Table::Row.new([
          Table::Cell.new(nature.code, reverse("liberal:nature", id: nature.id)),
          Table::Cell.new(nature.label),
          Table::Cell.new(I18n.t("ui.liberal.kinds.#{nature.kind}")),
          Table::Cell.new(heading_label(nature.heading)),
          Table::Cell.new(I18n.t(nature.enabled ? "ui.forms.active" : "ui.forms.inactive")),
        ], nature.enabled ? "" : "pd-row-closed")
      end
      table = Table.new(I18n.t("ui.liberal.natures.title"), columns, rows, reverse("liberal:natures"),
        empty_message: I18n.t("ui.liberal.natures.empty"))
      set_form(form, reverse("liberal:natures"), I18n.t("ui.forms.create"), title: I18n.t("ui.liberal.natures.new"))
      list_page(I18n.t("ui.liberal.natures.title"), table, settings_crumbs, "ui.liberal.natures.csv_name",
        intro: I18n.t("ui.liberal.natures.intro"), status: status, filter: false)
    end
  end

  class LiberalNatureHandler < LiberalSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      nature = find
      show(nature, LiberalNatureForm.build(self, nature.code, nature.label, nature.kind, nature.heading, nature.enabled))
    end

    def post
      require!(MODULE, SETTINGS)
      nature = find
      input = LiberalNatureForm.read(self)
      result = Liberal.update_nature(current.actor, nature.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.liberal.natures.updated", code: updated.code)
        return go(reverse("liberal:natures"))
      end
      show(nature, LiberalNatureForm.build(self, input.code, input.label, input.kind, input.heading, input.enabled)
        .add_errors(result.errors, fmt), 422)
    end

    private def find : Liberal::NatureView
      Liberal.natures(current.actor).find(&.id.==(id_param)) || raise Partiduo::Api::NotFound.new("liberal_nature", id_param)
    end

    private def show(nature : Liberal::NatureView, form : Form, status : Int32? = nil) : Marten::HTTP::Response
      form_page(I18n.t("ui.liberal.natures.edit", code: nature.code),
        settings_crumbs << Screen::Crumb.new(I18n.t("ui.liberal.natures.title"), reverse("liberal:natures")), form,
        reverse("liberal:nature", id: nature.id), I18n.t("ui.forms.save"), reverse("liberal:natures"),
        intro: I18n.t("ui.liberal.natures.edit_intro"), status: status)
    end
  end

  # Formulaire d'une nature : la rubrique est choisie dans la liste fermée
  # du contrat (recettes puis dépenses).
  module LiberalNatureForm
    def self.build(screen : LiberalScreen, code : String, label : String, kind : String, heading : String,
                   enabled : Bool) : Form
      kinds = Partiduo::Api::Liberal::KINDS.map { |value| screen.option(value, I18n.t("ui.liberal.kinds.#{value}")) }
      headings = Partiduo::Api::Liberal::HEADINGS.map do |value|
        side = Partiduo::Api::Liberal::RECEIPT_HEADINGS.includes?(value) ? "receipt" : "expense"
        screen.option(value, "#{I18n.t("ui.liberal.kinds.#{side}")} · #{screen.heading_label(value)}")
      end
      Form.new([Form::Group.new(nil, [
        Form::Field.new("code", I18n.t("ui.liberal.natures.code"), value: code, required: true, mono: true, maxlength: 32,
          help: I18n.t("ui.liberal.natures.code_help")),
        Form::Field.new("label", I18n.t("ui.liberal.natures.label"), value: label, required: true, maxlength: 100, wide: true),
        Form::Field.new("kind", I18n.t("ui.liberal.columns.kind"), "select", kind, required: true, options: kinds),
        Form::Field.new("heading", I18n.t("ui.liberal.fields.heading"), "select", heading, required: true, options: headings,
          help: I18n.t("ui.liberal.natures.heading_help")),
        Form::Field.new("enabled", I18n.t("ui.forms.enabled"), "checkbox", enabled ? "1" : ""),
      ])])
    end

    def self.read(screen : ReferenceHandler) : Partiduo::Api::Liberal::NatureInput
      Partiduo::Api::Liberal::NatureInput.new(screen.field("code"), screen.field("label"), screen.field("kind"),
        screen.field("heading"), screen.checkbox("enabled"))
    end
  end

  # Table de correspondance : lignes en vigueur pour un millésime
  # (`?millesime=`, défaut l'année en cours) ou toutes ; ajout ou
  # remplacement de la ligne d'un poste à partir d'un millésime ;
  # suppression d'une ligne.
  class LiberalFormLinesHandler < LiberalSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      show(build_form({"millesime" => millesime.to_s, "item" => query("item"), "form" => "2035-A", "line" => "", "box" => ""}))
    end

    def post
      require!(MODULE, SETTINGS)
      values = {"millesime" => field("millesime"), "item" => field("item"), "form" => field("form"), "line" => field("line"),
                "box" => field("box")}
      form = build_form(values)
      year = values["millesime"].to_i?
      form.add_error("millesime", I18n.t("ui.forms.invalid_integer")) unless year
      return show(form, 422) if year.nil?
      result = Liberal.set_form_line(current.actor, Liberal::FormLineInput.new(year, values["item"], values["form"],
        values["line"], values["box"]))
      if saved = result.value?
        flash["success"] = I18n.t("ui.liberal.form_lines.saved", item: item_label(saved.item), millesime: saved.millesime.to_s)
        return go("#{reverse("liberal:form_lines")}?millesime=#{saved.millesime}")
      end
      show(form.add_errors(result.errors, fmt), 422)
    end

    private def millesime : Int32
      query("millesime").to_i? || today.year
    end

    private def item_label(item : String) : String
      I18n.t(Liberal::HEADINGS.includes?(item) ? "liberal.headings.#{item}" : "liberal.items.#{item}")
    end

    private def build_form(values : Hash(String, String)) : Form
      items = [option("", I18n.t("ui.liberal.form_lines.choose"))] + Liberal::ITEMS.map { |code| option(code, item_label(code)) }
      forms = Liberal::FORMS.map { |code| option(code, code) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("millesime", I18n.t("ui.liberal.form_lines.millesime"), "number", values["millesime"], required: true, mono: true,
          help: I18n.t("ui.liberal.form_lines.millesime_help")),
        Form::Field.new("item", I18n.t("liberal.columns.item"), "select", values["item"], required: true, options: items),
        Form::Field.new("form", I18n.t("liberal.columns.form"), "select", values["form"], required: true, options: forms),
        Form::Field.new("line", I18n.t("liberal.columns.line"), value: values["line"], mono: true, maxlength: 10),
        Form::Field.new("box", I18n.t("liberal.columns.box"), value: values["box"], mono: true, maxlength: 10),
      ])])
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      year = millesime
      columns = [
        Table::Column.new("item", I18n.t("liberal.columns.item")),
        Table::Column.new("form", I18n.t("liberal.columns.form"), "mono"),
        Table::Column.new("line", I18n.t("liberal.columns.line"), "mono"),
        Table::Column.new("box", I18n.t("liberal.columns.box"), "mono"),
        Table::Column.new("millesime", I18n.t("ui.liberal.form_lines.from"), "mono", secondary: true),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = Liberal.form_lines(current.actor, year).map do |line|
        delete = post_action("ui.forms.delete", "#{reverse("liberal:form_line_delete", id: line.id)}?millesime=#{year}",
          "ui.liberal.form_lines.delete_confirm", "small")
        Table::Row.new([
          Table::Cell.new(item_label(line.item)), Table::Cell.new(line.form), Table::Cell.new(line.line),
          Table::Cell.new(line.box), Table::Cell.new(line.millesime.to_s), Table::Cell.new("", actions: [delete]),
        ])
      end
      tabs = ((today.year - 2)..today.year).map do |value|
        Screen::Tab.new(value.to_s, "#{reverse("liberal:form_lines")}?millesime=#{value}", value == year)
      end
      table = Table.new(I18n.t("ui.liberal.form_lines.caption", millesime: year.to_s), columns, rows, reverse("liberal:form_lines"),
        {"millesime" => year.to_s}, empty_message: I18n.t("ui.liberal.form_lines.empty"))
      set_form(form, reverse("liberal:form_lines"), I18n.t("ui.forms.save"), title: I18n.t("ui.liberal.form_lines.set"))
      list_page(I18n.t("ui.liberal.form_lines.title"), table, settings_crumbs, "ui.liberal.form_lines.csv_name",
        tabs: tabs, tabs_label: I18n.t("ui.liberal.form_lines.millesime"), intro: I18n.t("ui.liberal.form_lines.intro"),
        status: status)
    end
  end

  class LiberalFormLineDeleteHandler < LiberalSettingsScreen
    def post
      require!(MODULE, SETTINGS)
      result = Liberal.delete_form_line(current.actor, id_param)
      if result.success?
        flash["success"] = I18n.t("ui.liberal.form_lines.deleted")
      else
        flash["danger"] = messages(result.errors)
      end
      go("#{reverse("liberal:form_lines")}?millesime=#{query("millesime").to_i? || today.year}")
    end
  end

  # Valeurs par défaut (natures, table de correspondance) : ce qui existe
  # est conservé.
  class LiberalDefaultsHandler < LiberalSettingsScreen
    def post
      require!(MODULE, SETTINGS)
      count = Liberal.load_defaults(current.actor, I18n.locale)
      flash["success"] = I18n.t("ui.liberal.defaults.done", count: count)
      go(reverse("liberal:settings"))
    end
  end

  # Republication du livre-journal et des immobilisations vers la
  # Comptabilité (activée plus tard) ; rien n'est compté deux fois.
  class LiberalRepublishHandler < LiberalSettingsScreen
    def post
      require!(MODULE, SETTINGS)
      count = Liberal.republish(current.actor)
      flash["success"] = I18n.t("ui.liberal.republish.done", number: count.to_s)
      go(reverse("liberal:settings"))
    end
  end
end
