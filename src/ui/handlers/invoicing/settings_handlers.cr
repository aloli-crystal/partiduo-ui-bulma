# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Paramètres de la Facturation (menu `invoicing:settings`) et modèles de
  # mise en page (menu `invoicing:templates`). Tout passe par
  # `Api::Invoicing` ; le contrat contrôle chaque valeur, les erreurs
  # reviennent sous leur champ.
  class InvoicingSettingsHandler < InvoicingScreen
    PERMISSION = "invoicing.settings.manage"

    # Variables des textes de relance (`Reminders.interpolate` du cœur).
    REMINDER_VARIABLES = %w[number customer due_date days balance interest indemnity total seller]
      .map { |name| "%{#{name}}" }.join(", ")

    def get
      require!(MODULE, PERMISSION)
      show(settings_form(Inv.settings(current.actor).to_input))
    end

    def post
      require!(MODULE, PERMISSION)
      form_errors = [] of {String, String}
      input = read_input(form_errors)
      if form_errors.empty? && input
        result = Inv.update_settings(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("ui.invoicing.settings.saved")
          return go(reverse("invoicing:settings"))
        end
        return show(refused(input, form_errors, result.errors))
      end
      show(refused(input || Inv.settings(current.actor).to_input, form_errors))
    end

    private def show(form : Form) : Marten::HTTP::Response
      form_page(I18n.t("invoicing.menu.inv_settings"), [crumb("core.menu.settings")], form, reverse("invoicing:settings"),
        I18n.t("ui.forms.save"), intro: I18n.t("ui.invoicing.settings.intro"))
    end

    private def label(name : String) : String
      I18n.t("ui.invoicing.settings.fields.#{name}")
    end

    private def rate(value : BigDecimal?) : String
      value.try { |amount| fmt.input_number(amount, 4) } || ""
    end

    def settings_form(input : Inv::SettingsInput) : Form
      categories = Inv::OPERATION_CATEGORIES.map { |code| option(code, I18n.t("ui.invoicing.categories.#{code}")) }
      levels = (0..3).map { |level| option(level.to_s, I18n.t("ui.invoicing.settings.penalty_levels.l#{level}")) }
      Form.new([
        Form::Group.new(I18n.t("ui.invoicing.settings.groups.terms"), [
          Form::Field.new("payment_terms_days", label("payment_terms_days"), value: input.payment_terms_days.to_s, required: true, mono: true),
          Form::Field.new("quote_validity_days", label("quote_validity_days"), value: input.quote_validity_days.to_s, required: true, mono: true),
          Form::Field.new("late_penalty_rate", label("late_penalty_rate"), "number", rate(input.late_penalty_rate), mono: true,
            help: I18n.t("ui.invoicing.settings.late_penalty_help")),
          Form::Field.new("early_discount_rate", label("early_discount_rate"), "number", rate(input.early_discount_rate), mono: true),
          Form::Field.new("early_discount_days", label("early_discount_days"), value: input.early_discount_days.to_s, mono: true),
          Form::Field.new("default_operation_category", label("default_operation_category"), "select",
            input.default_operation_category, options: categories),
          Form::Field.new("vat_on_debits", label("vat_on_debits"), "checkbox", input.vat_on_debits ? "1" : ""),
        ]),
        Form::Group.new(I18n.t("ui.invoicing.settings.groups.payment"), [
          Form::Field.new("iban", label("iban"), value: input.iban, mono: true, maxlength: 42),
          Form::Field.new("bic", label("bic"), value: input.bic, mono: true, maxlength: 11),
          Form::Field.new("sender_email", label("sender_email"), "email", input.sender_email, maxlength: 254),
          Form::Field.new("sender_name", label("sender_name"), value: input.sender_name, maxlength: 128),
        ]),
        Form::Group.new(I18n.t("ui.invoicing.settings.groups.reminders"), [
          Form::Field.new("reminder1_days", label("reminder1_days"), value: input.reminder1_days.to_s, required: true, mono: true),
          Form::Field.new("reminder2_days", label("reminder2_days"), value: input.reminder2_days.to_s, required: true, mono: true),
          Form::Field.new("reminder3_days", label("reminder3_days"), value: input.reminder3_days.to_s, required: true, mono: true),
          Form::Field.new("penalty_from_level", label("penalty_from_level"), "select", input.penalty_from_level.to_s, options: levels),
          Form::Field.new("reminder_subject", label("reminder_subject"), value: input.reminder_subject, wide: true, maxlength: 255,
            help: I18n.t("ui.invoicing.settings.reminder_text_help", variables: REMINDER_VARIABLES)),
          Form::Field.new("reminder_body", label("reminder_body"), "textarea", input.reminder_body, wide: true),
        ]),
        Form::Group.new(I18n.t("ui.invoicing.settings.groups.export"), [
          Form::Field.new("sales_journal_code", label("sales_journal_code"), value: input.sales_journal_code, mono: true, maxlength: 8),
          Form::Field.new("bank_journal_code", label("bank_journal_code"), value: input.bank_journal_code, mono: true, maxlength: 8),
          Form::Field.new("customer_account", label("customer_account"), value: input.customer_account, mono: true, maxlength: 20),
          Form::Field.new("sales_account", label("sales_account"), value: input.sales_account, mono: true, maxlength: 20),
          Form::Field.new("vat_account", label("vat_account"), value: input.vat_account, mono: true, maxlength: 20),
          Form::Field.new("bank_account", label("bank_account"), value: input.bank_account, mono: true, maxlength: 20),
        ]),
        # Copie PDF doublant l'envoi par la plateforme agréée (ADR-004 D9).
        Form::Group.new(I18n.t("ui.invoicing.settings.groups.pdf_copy"), [
          Form::Field.new("pdf_copy_enabled", label("pdf_copy_enabled"), "checkbox", input.pdf_copy_enabled ? "1" : "",
            help: I18n.t("ui.invoicing.settings.pdf_copy_help")),
          Form::Field.new("pdf_copy_from", label("pdf_copy_from"), "date", date_key(input.pdf_copy_from)),
          Form::Field.new("pdf_copy_until", label("pdf_copy_until"), "date", date_key(input.pdf_copy_until)),
        ]),
      ])
    end

    # Saisie du formulaire ; `nil` si un nombre est illisible (erreurs sous
    # leur champ).
    private def read_input(errors : Array({String, String})) : Inv::SettingsInput?
      terms = integer("payment_terms_days", errors)
      validity = integer("quote_validity_days", errors)
      early_days = integer("early_discount_days", errors, required: false)
      reminders = {integer("reminder1_days", errors), integer("reminder2_days", errors), integer("reminder3_days", errors)}
      level = integer("penalty_from_level", errors)
      penalty = decimal("late_penalty_rate", errors)
      discount = decimal("early_discount_rate", errors)
      copy_from = field("pdf_copy_from").empty? ? nil : date("pdf_copy_from", errors)
      copy_until = field("pdf_copy_until").empty? ? nil : date("pdf_copy_until", errors)
      return unless errors.empty? && terms && validity && level && reminders.all?
      Inv::SettingsInput.new(
        payment_terms_days: terms, quote_validity_days: validity, late_penalty_rate: penalty,
        early_discount_rate: discount, early_discount_days: early_days, vat_on_debits: checkbox("vat_on_debits"),
        default_operation_category: field("default_operation_category"), iban: field("iban"), bic: field("bic"),
        sender_email: field("sender_email"), sender_name: field("sender_name"),
        reminder1_days: reminders[0] || 0, reminder2_days: reminders[1] || 0, reminder3_days: reminders[2] || 0,
        penalty_from_level: level, reminder_subject: field("reminder_subject"),
        reminder_body: field("reminder_body", strip: false).strip, sales_journal_code: field("sales_journal_code"),
        bank_journal_code: field("bank_journal_code"), customer_account: field("customer_account"),
        sales_account: field("sales_account"), vat_account: field("vat_account"), bank_account: field("bank_account"),
        pdf_copy_enabled: checkbox("pdf_copy_enabled"), pdf_copy_from: copy_from, pdf_copy_until: copy_until,
      )
    end

    # Formulaire refusé : valeurs saisies telles qu'écrites, erreurs.
    private def refused(input : Inv::SettingsInput, form_errors : Array({String, String}),
                        errors = [] of Partiduo::Api::FieldError) : Form
      form = settings_form(input)
      form.fields.each do |form_field|
        form_field.value = form_field.type == "checkbox" ? (checkbox(form_field.name) ? "1" : "") : field(form_field.name, strip: false)
      end
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end
  end

  # Modèles de mise en page : aspect des PDF (couleurs, en-tête, pied de
  # page), jamais les mentions ni les montants. Le logo se choisit par le
  # contrat (`logo_attachment_id`) ; l'écran le conserve (D-2F-011).
  abstract class LayoutScreen < InvoicingScreen
    PERMISSION = "invoicing.template.manage"

    def layout_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.settings"), crumb("invoicing.menu.inv_templates", reverse("invoicing:templates"))]
    end

    def layout_form(input : Inv::LayoutInput) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.invoicing.layouts.name"), value: input.name, required: true, maxlength: 100),
        Form::Field.new("primary_color", I18n.t("ui.invoicing.layouts.primary_color"), value: input.primary_color,
          mono: true, maxlength: 7, help: I18n.t("ui.invoicing.layouts.color_help")),
        Form::Field.new("text_color", I18n.t("ui.invoicing.layouts.text_color"), value: input.text_color, mono: true,
          maxlength: 7),
        Form::Field.new("header_text", I18n.t("ui.invoicing.layouts.header_text"), "textarea", input.header_text, wide: true),
        Form::Field.new("footer_text", I18n.t("ui.invoicing.layouts.footer_text"), "textarea", input.footer_text, wide: true),
        Form::Field.new("is_default", I18n.t("ui.invoicing.layouts.is_default"), "checkbox", input.is_default ? "1" : ""),
      ])])
    end

    def read_layout(logo : Int64?) : Inv::LayoutInput
      Inv::LayoutInput.new(name: field("name"), logo_attachment_id: logo, primary_color: field("primary_color"),
        text_color: field("text_color"), header_text: field("header_text", strip: false).strip,
        footer_text: field("footer_text", strip: false).strip, is_default: checkbox("is_default"))
    end
  end

  class LayoutsHandler < LayoutScreen
    def get
      require!(MODULE, PERMISSION)
      columns = [
        Table::Column.new("name", I18n.t("ui.invoicing.layouts.name")),
        Table::Column.new("colors", I18n.t("ui.invoicing.layouts.colors"), "mono", secondary: true),
        Table::Column.new("default", I18n.t("ui.invoicing.layouts.is_default")),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = Inv.layouts(current.actor).map do |layout|
        Table::Row.new([
          Table::Cell.new(layout.name, reverse("invoicing:template_edit", id: layout.id)),
          Table::Cell.new("#{layout.primary_color} · #{layout.text_color}"),
          Table::Cell.new(yes_no(layout.is_default)),
          Table::Cell.new("", actions: [post_action("ui.forms.delete", reverse("invoicing:template_delete", id: layout.id),
            "ui.invoicing.layouts.delete_confirm", "small")]),
        ])
      end
      table = Table.new(I18n.t("invoicing.menu.inv_templates"), columns, rows, reverse("invoicing:templates"),
        empty_message: I18n.t("ui.invoicing.layouts.empty"))
      actions = [link_action("ui.invoicing.layouts.new", reverse("invoicing:template_new"), "primary", "plus")]
      list_page(I18n.t("invoicing.menu.inv_templates"), table, layout_crumbs[0, 1], "ui.invoicing.layouts.csv_name", actions,
        intro: I18n.t("ui.invoicing.layouts.intro"))
    end
  end

  class LayoutNewHandler < LayoutScreen
    def get
      require!(MODULE, PERMISSION)
      show(layout_form(Inv::LayoutInput.new(name: "")))
    end

    def post
      require!(MODULE, PERMISSION)
      input = read_layout(nil)
      result = Inv.create_layout(current.actor, input)
      if layout = result.value?
        flash["success"] = I18n.t("ui.invoicing.layouts.created", name: layout.name)
        return go(reverse("invoicing:templates"))
      end
      show(layout_form(input).add_errors(result.errors, fmt))
    end

    private def show(form : Form) : Marten::HTTP::Response
      form_page(I18n.t("ui.invoicing.layouts.new"), layout_crumbs, form, reverse("invoicing:template_new"),
        I18n.t("ui.forms.create"), reverse("invoicing:templates"))
    end
  end

  class LayoutEditHandler < LayoutScreen
    def get
      require!(MODULE, PERMISSION)
      layout = Inv.layout(current.actor, id_param)
      show(layout, layout_form(Inv::LayoutInput.new(name: layout.name, logo_attachment_id: layout.logo_attachment_id,
        primary_color: layout.primary_color, text_color: layout.text_color, header_text: layout.header_text,
        footer_text: layout.footer_text, is_default: layout.is_default)))
    end

    def post
      require!(MODULE, PERMISSION)
      layout = Inv.layout(current.actor, id_param)
      input = read_layout(layout.logo_attachment_id)
      result = Inv.update_layout(current.actor, layout.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.invoicing.layouts.updated", name: updated.name)
        return go(reverse("invoicing:templates"))
      end
      show(layout, layout_form(input).add_errors(result.errors, fmt))
    end

    private def show(layout : Inv::LayoutView, form : Form) : Marten::HTTP::Response
      form_page(I18n.t("ui.invoicing.layouts.edit", name: layout.name), layout_crumbs, form,
        reverse("invoicing:template_edit", id: layout.id), I18n.t("ui.forms.save"), reverse("invoicing:templates"))
    end
  end

  class LayoutDeleteHandler < LayoutScreen
    def post
      layout = Inv.layout(current.actor, id_param)
      result = Inv.delete_layout(current.actor, layout.id)
      if result.success?
        flash["success"] = I18n.t("ui.invoicing.layouts.deleted", name: layout.name)
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(reverse("invoicing:templates"))
    end
  end
end
