# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Taux de TVA (`Partiduo::Api::Vat`, successeur de `tva_rate`) : liste,
  # création, consultation, modification, suppression. Un taux cité ne change
  # plus de taux ni de code : on en crée un autre et on désactive l'ancien.
  abstract class VatScreen < ReferenceHandler
    # Catégories UNCL5305 (`vat.categories.<code>`).
    CATEGORIES = %w[S Z E AE K G O L M]

    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.reference"), crumb("vat.menu.vat_rates", reverse("vat:rates"))]
    end

    def rate_form(values : Partiduo::Api::Vat::RateInput? = nil) : Form
      input = values || Partiduo::Api::Vat::RateInput.new(code: "", label: "", rate: BigDecimal.new(0), category: "S")
      categories = CATEGORIES.map { |code| option(code, "#{code} — #{I18n.t("vat.categories.#{code.downcase}")}") }
      Form.new([
        Form::Group.new(nil, [
          Form::Field.new("code", I18n.t("ui.vat.code"), value: input.code, required: true, mono: true, maxlength: 5,
            help: I18n.t("ui.vat.code_help")),
          Form::Field.new("label", I18n.t("ui.vat.label"), value: input.label, required: true, maxlength: 255, wide: true),
          Form::Field.new("rate", I18n.t("ui.vat.rate"), "number", fmt.input_number(input.rate, 4), required: true, mono: true,
            help: I18n.t("ui.vat.rate_help")),
          Form::Field.new("category", I18n.t("ui.vat.category"), "select", input.category || "S", options: categories, required: true),
          Form::Field.new("exemption_code", I18n.t("ui.vat.exemption_code"), value: input.exemption_code || "", mono: true,
            help: I18n.t("ui.vat.exemption_help")),
          Form::Field.new("exemption_reason", I18n.t("ui.vat.exemption_reason"), value: input.exemption_reason || "", wide: true),
          Form::Field.new("description", I18n.t("ui.vat.description"), "textarea", input.description || "", wide: true),
        ]),
        Form::Group.new(I18n.t("ui.vat.options"), [
          Form::Field.new("reverse_charge", I18n.t("ui.vat.reverse_charge"), "checkbox", flag(input.reverse_charge)),
          Form::Field.new("sale_on_payment", I18n.t("ui.vat.sale_on_payment"), "checkbox", flag(input.sale_on_payment)),
          Form::Field.new("purchase_on_payment", I18n.t("ui.vat.purchase_on_payment"), "checkbox", flag(input.purchase_on_payment)),
          Form::Field.new("enabled", I18n.t("ui.forms.enabled"), "checkbox", flag(input.enabled)),
        ]),
      ])
    end

    def flag(value : Bool) : String
      value ? "1" : ""
    end

    # Saisie du formulaire ; le taux mal écrit est signalé sous son champ.
    def read_input(form_errors : Array({String, String})) : Partiduo::Api::Vat::RateInput
      rate = decimal("rate", form_errors, required: true)
      Partiduo::Api::Vat::RateInput.new(
        code: field("code"), label: field("label"), rate: rate || BigDecimal.new(0),
        description: field("description", strip: false).strip, category: field("category"),
        exemption_code: field("exemption_code").presence, exemption_reason: field("exemption_reason").presence,
        reverse_charge: checkbox("reverse_charge"), sale_on_payment: checkbox("sale_on_payment"),
        purchase_on_payment: checkbox("purchase_on_payment"), enabled: checkbox("enabled"),
      )
    end

    # Formulaire refusé : valeurs saisies (taux tel qu'écrit) et erreurs.
    def refused_form(input, form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = rate_form(input)
      form.fields.find(&.name.==("rate")).try(&.value=(field("rate")))
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end
  end

  class VatRatesHandler < VatScreen
    def get
      all = checkbox_query("all")
      rates = Partiduo::Api::Vat.rates(current.actor, include_disabled: all)
      columns = [
        Table::Column.new("code", I18n.t("ui.vat.code"), "mono"),
        Table::Column.new("label", I18n.t("ui.vat.label")),
        Table::Column.new("rate", I18n.t("ui.vat.rate"), "amount"),
        Table::Column.new("category", I18n.t("ui.vat.category"), secondary: true),
        Table::Column.new("reverse_charge", I18n.t("ui.vat.reverse_charge_short"), secondary: true),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status")),
      ]
      rows = rates.map do |rate|
        Table::Row.new([
          Table::Cell.new(rate.code, reverse("vat:rate", id: rate.id)),
          Table::Cell.new(rate.label),
          Table::Cell.new(fmt.percent(rate.rate), sort: rate.rate, csv: fmt.number(rate.rate)),
          Table::Cell.new("#{rate.category} — #{I18n.t(rate.category_key)}", sort: rate.category),
          Table::Cell.new(yes_no(rate.reverse_charge)),
          Table::Cell.new(I18n.t(rate.enabled ? "ui.forms.active" : "ui.forms.inactive")),
        ], rate.enabled ? "" : "pd-row-closed")
      end
      params = all ? {"all" => "1"} : {} of String => String
      table = Table.new(I18n.t("vat.menu.vat_rates"), columns, rows, reverse("vat:rates"), params,
        empty_message: I18n.t("ui.vat.empty"))
      actions = [] of Screen::Action
      actions << link_action("ui.vat.new", reverse("vat:rate_new"), "primary", "plus") if can?("vat.rate.write")
      filters = search_filters([Form::Field.new("all", I18n.t("ui.vat.show_disabled"), "checkbox", all ? "1" : "")])
      list_page(I18n.t("vat.menu.vat_rates"), table, crumbs[0, 1], "ui.vat.csv_name", actions, filters: filters)
    end

    private def checkbox_query(name : String) : Bool
      query(name) == "1"
    end
  end

  class VatRateNewHandler < VatScreen
    def get
      require!("VAT", "vat.rate.write")
      form_page(I18n.t("ui.vat.new"), crumbs, rate_form, reverse("vat:rate_new"), I18n.t("ui.forms.create"), reverse("vat:rates"))
    end

    def post
      form_errors = [] of {String, String}
      input = read_input(form_errors)
      if form_errors.empty?
        result = Partiduo::Api::Vat.create_rate(current.actor, input)
        if rate = result.value?
          flash["success"] = I18n.t("ui.vat.created", code: rate.code)
          return go(reverse("vat:rate", id: rate.id))
        end
        return form_page(I18n.t("ui.vat.new"), crumbs, refused_form(input, form_errors, result.errors),
          reverse("vat:rate_new"), I18n.t("ui.forms.create"), reverse("vat:rates"))
      end
      form_page(I18n.t("ui.vat.new"), crumbs, refused_form(input, form_errors), reverse("vat:rate_new"),
        I18n.t("ui.forms.create"), reverse("vat:rates"))
    end
  end

  class VatRateHandler < VatScreen
    def get
      rate = Partiduo::Api::Vat.rate(current.actor, id_param)
      items = [
        Screen::Item.new(I18n.t("ui.vat.code"), rate.code, mono: true),
        Screen::Item.new(I18n.t("ui.vat.label"), rate.label),
        Screen::Item.new(I18n.t("ui.vat.rate"), fmt.percent(rate.rate), mono: true),
        Screen::Item.new(I18n.t("ui.vat.category"), "#{rate.category} — #{I18n.t(rate.category_key)}"),
        Screen::Item.new(I18n.t("ui.vat.exemption_code"), rate.exemption_code, mono: true),
        Screen::Item.new(I18n.t("ui.vat.exemption_reason"), rate.exemption_reason),
        Screen::Item.new(I18n.t("ui.vat.reverse_charge"), yes_no(rate.reverse_charge)),
        Screen::Item.new(I18n.t("ui.vat.sale_on_payment"), yes_no(rate.sale_on_payment)),
        Screen::Item.new(I18n.t("ui.vat.purchase_on_payment"), yes_no(rate.purchase_on_payment)),
        Screen::Item.new(I18n.t("ui.vat.description"), rate.description),
      ]
      actions = [] of Screen::Action
      if can?("vat.rate.write")
        actions << link_action("ui.forms.edit", reverse("vat:rate_edit", id: rate.id), "primary")
        actions << post_action("ui.forms.delete", reverse("vat:rate_delete", id: rate.id), "ui.vat.delete_confirm", "danger")
      end
      detail_page(I18n.t("ui.vat.title", code: rate.code), crumbs, [Screen::Section.new(rate.label, items)], actions,
        status_tag: rate.enabled ? nil : I18n.t("ui.forms.inactive"))
    end
  end

  class VatRateEditHandler < VatScreen
    def get
      require!("VAT", "vat.rate.write")
      rate = Partiduo::Api::Vat.rate(current.actor, id_param)
      show(rate_form(rate.to_input), rate.code)
    end

    def post
      rate = Partiduo::Api::Vat.rate(current.actor, id_param)
      form_errors = [] of {String, String}
      input = read_input(form_errors)
      if form_errors.empty?
        result = Partiduo::Api::Vat.update_rate(current.actor, rate.id, input)
        if updated = result.value?
          flash["success"] = I18n.t("ui.vat.updated", code: updated.code)
          return go(reverse("vat:rate", id: updated.id))
        end
        return show(refused_form(input, form_errors, result.errors), rate.code)
      end
      show(refused_form(input, form_errors), rate.code)
    end

    private def show(form : Form, code : String)
      form_page(I18n.t("ui.vat.edit", code: code), crumbs, form, reverse("vat:rate_edit", id: id_param),
        I18n.t("ui.forms.save"), reverse("vat:rate", id: id_param))
    end
  end

  class VatRateDeleteHandler < VatScreen
    def post
      rate = Partiduo::Api::Vat.rate(current.actor, id_param)
      if flash_result(Partiduo::Api::Vat.delete_rate(current.actor, rate.id), "ui.vat.deleted", {"code" => rate.code})
        go(reverse("vat:rates"))
      else
        go(reverse("vat:rate", id: rate.id))
      end
    end
  end
end
