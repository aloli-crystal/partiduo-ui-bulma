# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des écrans du référentiel (lot 1) : listes, formulaires et
  # consultations rendus par les gabarits génériques `ui/reference/*.html`
  # (DECISIONS D-UI-016). Tout passe par `Partiduo::Api`.
  abstract class ReferenceHandler < ScreenHandler
    # Page de liste : tableau préparé (filtre, tri, pages) ou export CSV.
    def list_page(title : String, table : Table, crumbs : Array(Screen::Crumb), csv_name : String,
                  actions = [] of Screen::Action, tabs : Array(Screen::Tab)? = nil, tabs_label : String = "",
                  filters : Form? = nil, intro : String? = nil, status : Int32 = 200,
                  filter : Bool = true) : Marten::HTTP::Response
      prepare(table, filter)
      return csv_response(table, csv_name) if csv?
      context["title"] = title
      context["crumbs"] = crumbs
      context["actions"] = actions
      context["tabs"] = tabs.try { |list| Screen.listed(list) }
      context["tabs_label"] = tabs_label
      context["filters"] = filters || search_filters
      context["table"] = table
      context["intro"] = intro
      page("ui/reference/list.html", status: status)
    end

    def form_page(title : String, crumbs : Array(Screen::Crumb), form : Form?, action : String, submit : String,
                  cancel_url : String? = nil, actions = [] of Screen::Action, intro : String? = nil,
                  status : Int32? = nil) : Marten::HTTP::Response
      context["title"] = title
      context["crumbs"] = crumbs
      context["actions"] = actions
      context["intro"] = intro
      set_form(form, action, submit, cancel_url)
      page("ui/reference/form.html", status: status || (form.try(&.invalid) ? 422 : 200))
    end

    def detail_page(title : String, crumbs : Array(Screen::Crumb), sections : Array(Screen::Section),
                    actions = [] of Screen::Action, status_tag : String? = nil, intro : String? = nil,
                    status : Int32 = 200) : Marten::HTTP::Response
      context["title"] = title
      context["crumbs"] = crumbs
      context["actions"] = actions
      context["sections"] = sections
      context["status"] = status_tag
      context["intro"] = intro
      page("ui/reference/detail.html", status: status)
    end

    # Formulaire affiché sous une liste ou une consultation.
    def set_form(form : Form?, action : String, submit : String, cancel_url : String? = nil, title : String? = nil) : Nil
      context["form"] = form
      context["form_action"] = action
      context["form_submit"] = submit
      context["form_title"] = title || submit
      context["cancel_url"] = cancel_url
    end

    # Filtre texte seul, commun à toutes les listes.
    def search_filters(extra = [] of Form::Field) : Form
      fields = [Form::Field.new("q", I18n.t("ui.table.search"), value: query("q"), placeholder: I18n.t("ui.table.search_placeholder"))]
      Form.new([Form::Group.new(nil, fields + extra)])
    end

    # Après une commande : message de succès, ou erreurs du contrat.
    def flash_result(result, success_key : String, params = {} of String => String) : Bool
      if result.success?
        flash["success"] = I18n.t(success_key, params)
        true
      else
        flash["danger"] = result.errors.map(&.message).join(" ")
        false
      end
    end

    # Écran d'une commande : module actif et permission, vérifiés avant
    # d'afficher le formulaire (le contrat les vérifie de nouveau à l'envoi).
    def require!(module_code : String, permission : String) : Nil
      raise Partiduo::Api::ModuleDisabled.new(module_code) unless module_active?(module_code)
      raise Partiduo::Api::Forbidden.new(permission) unless can?(permission)
    end

    def checkbox(name : String) : Bool
      field(name) == "1"
    end

    # Entier saisi ; `nil` et une erreur de formulaire s'il n'en est pas un.
    def integer(name : String, errors : Array({String, String}), required : Bool = true) : Int32?
      text = field(name)
      return if text.empty? && !required
      value = text.to_i?
      errors << {name, I18n.t("ui.forms.invalid_integer")} unless value
      value
    end

    def decimal(name : String, errors : Array({String, String}), required : Bool = false) : BigDecimal?
      text = field(name)
      if text.empty?
        errors << {name, I18n.t("ui.forms.required")} if required
        return
      end
      value = Format.parse_decimal(text)
      errors << {name, I18n.t("ui.forms.invalid_number")} unless value
      value
    end

    def date(name : String, errors : Array({String, String})) : Time?
      value = fmt.parse_date(field(name))
      errors << {name, I18n.t("ui.forms.invalid_date")} unless value
      value
    end

    # Libellé traduit d'une option de liste (`Form::Option`).
    def option(value : String, label : String) : Form::Option
      Form::Option.new(value, label)
    end

    def yes_no(value : Bool) : String
      I18n.t(value ? "ui.forms.answer_yes" : "ui.forms.answer_no")
    end

    def post_action(label_key : String, url : String, confirm_key : String? = nil, style : String = "", icon : String? = nil) : Screen::Action
      Screen::Action.new(I18n.t(label_key), url, "post", style, icon, confirm_key.try { |key| I18n.t(key) })
    end

    def link_action(label_key : String, url : String, style : String = "", icon : String? = nil) : Screen::Action
      Screen::Action.new(I18n.t(label_key), url, "get", style, icon)
    end

    # Clé de tri d'une date (ISO), d'un nombre.
    def date_key(value : Time?) : String
      value.try(&.to_s("%Y-%m-%d")) || ""
    end
  end
end
