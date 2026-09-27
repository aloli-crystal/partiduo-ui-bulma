# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Paramétrage de la micro-entreprise au-delà des réglages courants
  # (ADR-007 D1, D2) : natures des recettes et des achats, paramètres datés
  # (taux URSSAF, seuils, cases de la 2042-C-PRO), nature des articles,
  # bascules guidées vers la TVA et vers le régime réel, republication des
  # registres vers la Comptabilité. Tout passe par `Partiduo::Api::Micro` ;
  # les commandes exigent `micro.settings.write` (et, pour les bascules,
  # `cards.card.write` ou `core.modules.manage`, vérifiées par le contrat).
  abstract class MicroSettingsScreen < MicroScreen
    def settings_crumbs : Array(Screen::Crumb)
      micro_crumbs << Screen::Crumb.new(I18n.t("ui.micro.settings.title"), reverse("micro:settings"))
    end

    def refused(form : Form, errors : Array(Partiduo::Api::FieldError)) : Form
      form.add_errors(errors, fmt)
    end
  end

  # Natures : liste, création sous la liste. Une nature employée ne change
  # plus que de libellé et d'activation (règle du contrat).
  class MicroNaturesHandler < MicroSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      show(MicroNatureForm.build(self, "", "", "receipt", "sale_bic", true))
    end

    def post
      require!(MODULE, SETTINGS)
      input = MicroNatureForm.read(self)
      result = Micro.create_nature(current.actor, input)
      if nature = result.value?
        flash["success"] = I18n.t("ui.micro.natures.created", code: nature.code)
        return go(reverse("micro:natures"))
      end
      show(refused(MicroNatureForm.build(self, input.code, input.label, input.kind, input.category, input.enabled),
        result.errors), 422)
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      columns = [
        Table::Column.new("code", I18n.t("ui.micro.natures.code"), "mono"),
        Table::Column.new("label", I18n.t("ui.micro.natures.label")),
        Table::Column.new("kind", I18n.t("ui.micro.natures.kind")),
        Table::Column.new("category", I18n.t("ui.micro.natures.category"), secondary: true),
        Table::Column.new("status", I18n.t("ui.micro.natures.status"), secondary: true),
      ]
      rows = Micro.natures(current.actor).map do |nature|
        Table::Row.new([
          Table::Cell.new(nature.code, reverse("micro:nature", id: nature.id)),
          Table::Cell.new(nature.label),
          Table::Cell.new(I18n.t("ui.micro.natures.kinds.#{nature.kind}")),
          Table::Cell.new(category_label(nature.category)),
          Table::Cell.new(I18n.t(nature.enabled ? "ui.forms.active" : "ui.forms.inactive")),
        ], nature.enabled ? "" : "pd-row-closed")
      end
      table = Table.new(I18n.t("ui.micro.natures.title"), columns, rows, reverse("micro:natures"),
        empty_message: I18n.t("ui.micro.natures.empty"))
      set_form(form, reverse("micro:natures"), I18n.t("ui.forms.create"), title: I18n.t("ui.micro.natures.new"))
      list_page(I18n.t("ui.micro.natures.title"), table, settings_crumbs, "ui.micro.natures.csv_name",
        intro: I18n.t("ui.micro.natures.intro"), status: status, filter: false)
    end
  end

  # Modification d'une nature.
  class MicroNatureHandler < MicroSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      nature = find
      show(nature, MicroNatureForm.build(self, nature.code, nature.label, nature.kind, nature.category, nature.enabled))
    end

    def post
      require!(MODULE, SETTINGS)
      nature = find
      input = MicroNatureForm.read(self)
      result = Micro.update_nature(current.actor, nature.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.micro.natures.updated", code: updated.code)
        return go(reverse("micro:natures"))
      end
      show(nature, refused(MicroNatureForm.build(self, input.code, input.label, input.kind, input.category, input.enabled),
        result.errors), 422)
    end

    private def find : Micro::NatureView
      Micro.natures(current.actor).find(&.id.==(id_param)) || raise Partiduo::Api::NotFound.new("micro_nature", id_param)
    end

    private def show(nature : Micro::NatureView, form : Form, status : Int32? = nil) : Marten::HTTP::Response
      form_page(I18n.t("ui.micro.natures.edit", code: nature.code),
        settings_crumbs << Screen::Crumb.new(I18n.t("ui.micro.natures.title"), reverse("micro:natures")), form,
        reverse("micro:nature", id: nature.id), I18n.t("ui.forms.save"), reverse("micro:natures"),
        intro: I18n.t("ui.micro.natures.edit_intro"), status: status)
    end
  end

  # Formulaire d'une nature (création et modification).
  module MicroNatureForm
    def self.build(screen : MicroScreen, code : String, label : String, kind : String, category : String,
                   enabled : Bool) : Form
      kinds = Partiduo::Api::Micro::KINDS.map { |value| screen.option(value, I18n.t("ui.micro.natures.kinds.#{value}")) }
      categories = (Partiduo::Api::Micro::RECEIPT_CATEGORIES + Partiduo::Api::Micro::PURCHASE_CATEGORIES).map do |value|
        screen.option(value, screen.category_label(value))
      end
      Form.new([Form::Group.new(nil, [
        Form::Field.new("code", I18n.t("ui.micro.natures.code"), value: code, required: true, mono: true, maxlength: 24,
          help: I18n.t("ui.micro.natures.code_help")),
        Form::Field.new("label", I18n.t("ui.micro.natures.label"), value: label, required: true, maxlength: 100, wide: true),
        Form::Field.new("kind", I18n.t("ui.micro.natures.kind"), "select", kind, required: true, options: kinds),
        Form::Field.new("category", I18n.t("ui.micro.natures.category"), "select", category, required: true,
          options: categories, help: I18n.t("ui.micro.natures.category_help")),
        Form::Field.new("enabled", I18n.t("ui.forms.enabled"), "checkbox", enabled ? "1" : ""),
      ])])
    end

    def self.read(screen : ReferenceHandler) : Partiduo::Api::Micro::NatureInput
      Partiduo::Api::Micro::NatureInput.new(screen.field("code"), screen.field("label"), screen.field("kind"),
        screen.field("category"), screen.checkbox("enabled"))
    end
  end

  # Paramètres datés : liste (suppression par ligne), ajout ou remplacement
  # d'une valeur à partir d'une date (taux et seuils vérifiés chaque année,
  # D-MIC-006).
  class MicroParametersHandler < MicroSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      show(build_form({"code" => query("code"), "valid_from" => "#{today.year}-01-01", "value" => "", "text" => ""}))
    end

    def post
      require!(MODULE, SETTINGS)
      values = {"code" => field("code"), "valid_from" => field("valid_from"), "value" => field("value"), "text" => field("text")}
      form = build_form(values)
      valid_from = fmt.parse_date(values["valid_from"])
      form.add_error("valid_from", I18n.t("ui.forms.invalid_date")) unless valid_from
      value = values["value"].empty? ? nil : fmt.parse_decimal(values["value"])
      form.add_error("value", I18n.t("ui.forms.invalid_number")) if value.nil? && !values["value"].empty?
      return show(form, 422) if form.invalid || valid_from.nil?
      result = Micro.set_parameter(current.actor, Micro::ParameterInput.new(values["code"], valid_from, value, values["text"]))
      if saved = result.value?
        flash["success"] = I18n.t("ui.micro.parameters.saved", label: MicroText.parameter_label(saved.code),
          date: fmt.date(saved.valid_from))
        return go(reverse("micro:parameters"))
      end
      show(refused(form, result.errors), 422)
    end

    private def build_form(values : Hash(String, String)) : Form
      codes = Micro::PARAMETER_CODES.map { |code| option(code, "#{MicroText.parameter_label(code)} (#{code})") }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("code", I18n.t("ui.micro.parameters.code"), "select", values["code"], required: true, options: codes,
          wide: true),
        Form::Field.new("valid_from", I18n.t("ui.micro.parameters.valid_from"), "date", values["valid_from"], required: true),
        Form::Field.new("value", I18n.t("ui.micro.parameters.value"), "number", values["value"], mono: true,
          help: I18n.t("ui.micro.parameters.value_help")),
        Form::Field.new("text", I18n.t("ui.micro.parameters.text"), value: values["text"], mono: true, maxlength: 60,
          help: I18n.t("ui.micro.parameters.text_help")),
      ])])
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      columns = [
        Table::Column.new("label", I18n.t("ui.micro.parameters.code")),
        Table::Column.new("valid_from", I18n.t("ui.micro.parameters.valid_from"), "mono"),
        Table::Column.new("value", I18n.t("ui.micro.parameters.value"), "amount"),
        Table::Column.new("actions", "", sortable: false),
      ]
      rows = Micro.parameters(current.actor).map do |parameter|
        shown = parameter.code.starts_with?("box.") ? parameter.text : value_text(parameter)
        Table::Row.new([
          Table::Cell.new(MicroText.parameter_label(parameter.code), sort: "#{parameter.code} #{date_key(parameter.valid_from)}",
            csv: parameter.code),
          Table::Cell.new(fmt.date(parameter.valid_from), sort: date_key(parameter.valid_from), csv: date_key(parameter.valid_from)),
          Table::Cell.new(shown, csv: parameter.value.try(&.to_s) || parameter.text),
          Table::Cell.new("", actions: [post_action("ui.forms.delete", reverse("micro:parameter_delete", id: parameter.id),
            "ui.micro.parameters.delete_confirm", "danger")]),
        ])
      end
      table = Table.new(I18n.t("ui.micro.parameters.title"), columns, rows, reverse("micro:parameters"),
        empty_message: I18n.t("ui.micro.parameters.empty"))
      set_form(form, reverse("micro:parameters"), I18n.t("ui.forms.save"), title: I18n.t("ui.micro.parameters.new"))
      list_page(I18n.t("ui.micro.parameters.title"), table, settings_crumbs, "ui.micro.parameters.csv_name",
        intro: I18n.t("ui.micro.parameters.intro"), status: status)
    end

    # Taux en %, seuil en euros, ratio d'alerte en %.
    private def value_text(parameter : Micro::ParameterView) : String
      value = parameter.value || return ""
      parameter.code.starts_with?("threshold.") ? euros(value, 0) : fmt.percent(value)
    end
  end

  class MicroParameterDeleteHandler < MicroSettingsScreen
    def post
      require!(MODULE, SETTINGS)
      flash_result(Micro.delete_parameter(current.actor, id_param), "ui.micro.parameters.deleted")
      go(reverse("micro:parameters"))
    end
  end

  # Nature de recette des articles : une facture encaissée se ventile par
  # la nature de ses articles (sinon la nature par défaut des paramètres).
  class MicroItemNaturesHandler < MicroSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      show(build_form("", ""))
    end

    def post
      require!(MODULE, SETTINGS)
      item_id = field("item_card_id").to_i64?
      form = build_form(field("item_card_id"), field("nature_id"))
      form.add_error("item_card_id", I18n.t("ui.forms.required")) unless item_id
      return show(form, 422) if item_id.nil?
      result = Micro.set_item_nature(current.actor, item_id, field("nature_id").to_i64?)
      if result.success?
        flash["success"] = I18n.t("ui.micro.items.saved")
        return go(reverse("micro:items"))
      end
      show(refused(form, result.errors), 422)
    end

    private def items : Array(Partiduo::Api::Cards::CardView)
      Partiduo::Api::Cards.cards(current.actor, Partiduo::Api::Cards::CardQuery.new(kind: "item", limit: 1000))
    rescue Partiduo::Api::AccessDenied
      [] of Partiduo::Api::Cards::CardView
    end

    private def build_form(item : String, nature : String) : Form
      item_options = [option("", I18n.t("ui.micro.items.choose"))] +
                     items.map { |card| option(card.id.to_s, [card.code, card.name].compact.reject(&.empty?).join(" · ")) }
      natures = [option("", I18n.t("ui.micro.items.default_nature"))] +
                Micro.natures(current.actor, "receipt").map { |row| option(row.id.to_s, row.label) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("item_card_id", I18n.t("ui.micro.items.item"), "select", item, required: true, options: item_options),
        Form::Field.new("nature_id", I18n.t("ui.micro.items.nature"), "select", nature, options: natures,
          help: I18n.t("ui.micro.items.nature_help")),
      ])])
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      natures = Micro.natures(current.actor).index_by(&.id)
      assigned = Micro.item_natures(current.actor).to_h { |row| {row.item_card_id, row.nature_id} }
      columns = [
        Table::Column.new("item", I18n.t("ui.micro.items.item")),
        Table::Column.new("nature", I18n.t("ui.micro.items.nature")),
      ]
      known = items.index_by(&.id)
      ids = (known.keys + assigned.keys).uniq!
      rows = ids.map do |id|
        card = known[id]?
        name = card.try { |found| [found.code, found.name].compact.reject(&.empty?).join(" · ") } || "##{id}"
        nature = assigned[id]?.try { |nature_id| natures[nature_id]?.try(&.label) } || I18n.t("ui.micro.items.default_nature")
        Table::Row.new([Table::Cell.new(name), Table::Cell.new(nature)])
      end
      table = Table.new(I18n.t("ui.micro.items.title"), columns, rows, reverse("micro:items"),
        empty_message: I18n.t("ui.micro.items.empty"))
      set_form(form, reverse("micro:items"), I18n.t("ui.forms.save"), title: I18n.t("ui.micro.items.assign"))
      list_page(I18n.t("ui.micro.items.title"), table, settings_crumbs, "ui.micro.items.csv_name",
        intro: I18n.t("ui.micro.items.intro"), status: status)
    end
  end

  # Bascule guidée vers la TVA : articles en franchise (mention 293 B) et
  # taux proposé ; la confirmation leur donne le taux choisi et note la
  # date. Exige aussi `cards.card.write` (contrat).
  class MicroVatSwitchHandler < MicroSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      show(nil)
    end

    def post
      require!(MODULE, SETTINGS)
      effective_on = fmt.parse_date(field("effective_on"))
      rate_id = field("rate_id").to_i64?
      form = build_form(field("effective_on"), field("rate_id"))
      form.add_error("effective_on", I18n.t("ui.forms.invalid_date")) unless effective_on
      form.add_error("rate_id", I18n.t("ui.forms.required")) unless rate_id
      return show(form, 422) if effective_on.nil? || rate_id.nil?
      result = Micro.switch_to_vat(current.actor, Micro::VatSwitchInput.new(effective_on, rate_id))
      if result.success?
        flash["success"] = I18n.t("ui.micro.switch.vat.done", date: fmt.date(effective_on))
        return go(reverse("micro:settings"))
      end
      show(refused(form, result.errors), 422)
    end

    private def rates : Array(Partiduo::Api::Vat::RateView)
      Partiduo::Api::Vat.rates(current.actor).select { |rate| rate.rate > 0 && rate.exemption_code.nil? && !rate.reverse_charge }
    end

    private def build_form(effective_on : String, rate_id : String) : Form
      options = rates.map { |rate| option(rate.id.to_s, "#{rate.label} (#{fmt.percent(rate.rate)})") }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("effective_on", I18n.t("ui.micro.switch.effective_on"), "date", effective_on, required: true,
          help: I18n.t("ui.micro.switch.vat.effective_help")),
        Form::Field.new("rate_id", I18n.t("ui.micro.switch.vat.rate"), "select", rate_id, required: true, options: options),
      ])])
    end

    private def show(form : Form?, status : Int32 = 200) : Marten::HTTP::Response
      settings = Micro.settings(current.actor)
      title = I18n.t("ui.micro.switch.vat.title")
      if since = settings.vat_liable_since
        return detail_page(title, settings_crumbs, [] of Screen::Section,
          intro: I18n.t("ui.micro.switch.vat.already", date: fmt.date(since)))
      end
      plan = Micro.vat_switch_plan(current.actor)
      columns = [
        Table::Column.new("code", I18n.t("ui.micro.switch.vat.item_code"), "mono"),
        Table::Column.new("name", I18n.t("ui.micro.switch.vat.item_name")),
        Table::Column.new("rate", I18n.t("ui.micro.switch.vat.current_rate"), "mono", secondary: true),
      ]
      rows = plan.items.map do |item|
        Table::Row.new([Table::Cell.new(item.code), Table::Cell.new(item.name), Table::Cell.new(item.rate_code)])
      end
      table = Table.new(I18n.t("ui.micro.switch.vat.items"), columns, rows, reverse("micro:switch_vat"),
        empty_message: I18n.t("ui.micro.switch.vat.no_items"))
      table.exportable = false
      sections = [Screen::Section.new(I18n.t("ui.micro.switch.vat.items"), table: table)]
      if can?("cards.card.write")
        set_form(form || build_form(today.to_s("%Y-%m-%d"), plan.suggested_rate_id.try(&.to_s) || ""),
          reverse("micro:switch_vat"), I18n.t("ui.micro.switch.vat.confirm"), title: I18n.t("ui.micro.switch.vat.confirm"))
      else
        sections << Screen::Section.new(I18n.t("ui.micro.switch.rights"), note: I18n.t("ui.micro.switch.vat.rights"))
      end
      detail_page(title, settings_crumbs, sections, intro: I18n.t("ui.micro.switch.vat.intro"), status: status)
    end
  end

  # Bascule guidée vers le régime réel : active la Comptabilité, note la
  # date, republie les registres. Exige aussi `core.modules.manage`.
  class MicroRealSwitchHandler < MicroSettingsScreen
    def get
      require!(MODULE, SETTINGS)
      show(nil)
    end

    def post
      require!(MODULE, SETTINGS)
      effective_on = fmt.parse_date(field("effective_on"))
      form = build_form(field("effective_on"))
      unless effective_on
        form.add_error("effective_on", I18n.t("ui.forms.invalid_date"))
        return show(form, 422)
      end
      result = Micro.switch_to_real(current.actor, effective_on)
      if result.success?
        flash["success"] = I18n.t("ui.micro.switch.real.done", date: fmt.date(effective_on))
        return go(reverse("micro:settings"))
      end
      show(refused(form, result.errors), 422)
    end

    private def build_form(effective_on : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("effective_on", I18n.t("ui.micro.switch.effective_on"), "date", effective_on, required: true,
          help: I18n.t("ui.micro.switch.real.effective_help")),
      ])])
    end

    private def show(form : Form?, status : Int32 = 200) : Marten::HTTP::Response
      settings = Micro.settings(current.actor)
      title = I18n.t("ui.micro.switch.real.title")
      if since = settings.real_regime_since
        return detail_page(title, settings_crumbs, [] of Screen::Section,
          intro: I18n.t("ui.micro.switch.real.already", date: fmt.date(since)))
      end
      sections = [] of Screen::Section
      if can?("core.modules.manage")
        next_year = Time.utc(today.year + 1, 1, 1).to_s("%Y-%m-%d")
        set_form(form || build_form(next_year), reverse("micro:switch_real"), I18n.t("ui.micro.switch.real.confirm"),
          title: I18n.t("ui.micro.switch.real.confirm"))
      else
        sections << Screen::Section.new(I18n.t("ui.micro.switch.rights"), note: I18n.t("ui.micro.switch.real.rights"))
      end
      detail_page(title, settings_crumbs, sections, intro: I18n.t("ui.micro.switch.real.intro"), status: status)
    end
  end

  # Republie les registres vers la Comptabilité (après le chargement du plan
  # comptable, D-MIC-009) ; une ligne déjà comptabilisée ne l'est pas deux
  # fois.
  class MicroRepublishHandler < MicroSettingsScreen
    def post
      require!(MODULE, SETTINGS)
      count = Micro.republish(current.actor)
      flash["success"] = I18n.t("ui.micro.republish.done", lines: count.to_s)
      go(reverse("micro:settings"))
    end
  end
end
