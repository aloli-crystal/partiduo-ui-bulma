# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Déclarations de TVA (lot 4, menu « TVA ») : préparation (déclaration
  # calculée sans être enregistrée), déclaration enregistrée (cases par
  # cadre, relevés, corrections, recalcul, clôture et écriture de
  # liquidation), contrôle (apport de chaque règle, écritures modifiées
  # depuis le calcul), historique, exports (XML Intervat, CSV, PDF) et
  # paramètres (mandataire, règles de calcul des cases). Successeur des
  # écrans de l'extension TVA d'origine (`sa=dec`, `li`, `lc`,
  # `ltva`, `param`). Tout vient de `Partiduo::Api::Accounting` : l'interface
  # ne calcule aucune case (D-UI-039).
  abstract class VatScreenBase < AccountingScreen
    MODULE     = "ACCOUNTING"
    PERMISSION = "accounting.vat.declare"

    # Critères de la préparation (et de l'enregistrement).
    CRITERIA = %w[form year periodicity number date_from date_to exigibility threshold]

    @forms : Array(Acc::VatFormView)?

    def forms : Array(Acc::VatFormView)
      @forms ||= Acc.vat_forms(current.actor)
    end

    def form_view(code : String) : Acc::VatFormView?
      forms.find(&.form.==(code))
    end

    def form_name(code : String) : String
      I18n.t("vat.forms.#{code}")
    end

    def vat_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.vat")]
    end

    # Onglets communs : préparation, historique, paramètres.
    def vat_tabs(current_tab : String) : Array(Screen::Tab)
      [
        Screen::Tab.new(I18n.t("ui.vat_returns.tabs.prepare"), reverse("accounting:vat_return"), current_tab == "prepare"),
        Screen::Tab.new(I18n.t("ui.vat_returns.tabs.history"), reverse("accounting:vat_returns"), current_tab == "history"),
        Screen::Tab.new(I18n.t("ui.vat_returns.tabs.settings"), reverse("accounting:vat_settings"), current_tab == "settings"),
      ]
    end

    # Page d'un écran de TVA (`ui/vat/page.html`).
    def vat_page(title : String, tab : String?, sections : Array(Screen::Section), crumbs : Array(Screen::Crumb) = vat_crumbs,
                 actions = [] of Screen::Action, filters : Form? = nil, summary : Array(Screen::Item)? = nil,
                 warnings : Array(String) = [] of String, intro : String? = nil, status_tag : String? = nil,
                 status : Int32 = 200) : Marten::HTTP::Response
      context["title"] = title
      context["crumbs"] = crumbs
      context["actions"] = actions
      context["tabs"] = tab.try { |value| vat_tabs(value) }
      context["tabs_label"] = I18n.t("ui.vat_returns.tabs.label")
      context["filters"] = filters
      context["filters_title"] = I18n.t("ui.vat_returns.criteria")
      context["filters_path"] = request.path
      context["submit_label"] = I18n.t("ui.vat_returns.compute")
      context["summary"] = summary.try { |items| Screen.listed(items.reject(&.value.empty?)) }
      context["summary_title"] = I18n.t("ui.reports.summary")
      context["warnings"] = Screen.listed(warnings)
      context["sections"] = sections
      context["intro"] = intro
      context["status"] = status_tag
      page("ui/vat/page.html", status: status)
    end

    def criteria_params : Hash(String, String)
      PersistentFilters.pick(request.query_params, CRITERIA)
    end

    # Critères lus dans l'adresse ; par défaut, la période qui contient le
    # jour de référence (période de travail).
    def read_criteria(errors : Array({String, String})) : Acc::VatReturnInput
      day = reference_day
      form = query("form").presence || forms.first?.try(&.form) || ""
      allowed = form_view(form).try(&.periodicities) || %w[month quarter year]
      periodicity = query("periodicity").presence || (allowed.includes?("quarter") ? "quarter" : allowed.first)
      default_number = case periodicity
                       when "month"   then day.month
                       when "quarter" then (day.month - 1) // 3 + 1
                       else                1
                       end
      year = query_int("year", day.year, errors)
      number = query_int("number", default_number, errors)
      date_from = query_date("date_from", errors)
      date_to = query_date("date_to", errors)
      threshold = nil
      unless (text = query("threshold")).empty?
        threshold = fmt.parse_decimal(text)
        errors << {"threshold", I18n.t("ui.forms.invalid_number")} unless threshold
      end
      Acc::VatReturnInput.new(form: form, year: year, periodicity: periodicity, number: number, date_from: date_from,
        date_to: date_to, exigibility: query("exigibility").presence || "rates", threshold: threshold)
    end

    def query_int(name : String, default : Int32, errors : Array({String, String})) : Int32
      text = query(name)
      return default if text.empty?
      value = text.to_i?
      errors << {name, I18n.t("ui.forms.invalid_integer")} unless value
      value || default
    end

    def query_date(name : String, errors : Array({String, String})) : Time?
      text = query(name)
      return if text.empty?
      day = fmt.parse_short_date(text, reference_day)
      errors << {name, I18n.t("ui.forms.invalid_date")} unless day
      day
    end

    # --- Présentation d'une déclaration --------------------------------------------

    def period_label(view : Acc::VatReturnView) : String
      name = case view.periodicity
             when "month"
               fmt.month(view.date_from)
             when "quarter"
               I18n.t("ui.vat_returns.quarter", number: view.number.to_s, year: view.year.to_s)
             else
               I18n.t("ui.vat_returns.year", year: view.year.to_s)
             end
      "#{name} (#{fmt.date(view.date_from)} – #{fmt.date(view.date_to)})"
    end

    def status_label(status : String) : String
      I18n.t("ui.vat_returns.statuses.#{status}")
    end

    def exigibility_label(value : String) : String
      I18n.t("ui.vat_returns.exigibilities.#{value}")
    end

    def amount_cell(value : BigDecimal) : Table::Cell
      Table::Cell.new(fmt.amount(value), sort: value, csv: fmt.csv_amount(value))
    end

    # Cases d'une déclaration, une rubrique par cadre (ordre du formulaire).
    # `saved` : colonnes « calculé » et « déclaré » ; sinon, le calculé seul.
    def box_sections(view : Acc::VatReturnView, saved : Bool) : Array(Screen::Section)
      groups = [] of {String, Array(Acc::VatBoxView)}
      view.boxes.each do |box|
        if (last = groups.last?) && last[0] == box.section_key
          last[1] << box
        else
          groups << {box.section_key, [box]}
        end
      end
      columns = [
        Table::Column.new("code", I18n.t("ui.vat_returns.box"), "mono", sortable: false),
        Table::Column.new("label", I18n.t("ui.vat_returns.box_label"), sortable: false),
      ]
      if saved
        columns << Table::Column.new("computed", I18n.t("ui.vat_returns.computed"), "amount", secondary: true, sortable: false)
        columns << Table::Column.new("amount", I18n.t("ui.vat_returns.declared"), "amount", sortable: false)
        columns << Table::Column.new("adjusted", I18n.t("ui.vat_returns.adjusted"), secondary: true, sortable: false)
      else
        columns << Table::Column.new("amount", I18n.t("ui.vat_returns.amount"), "amount", sortable: false)
      end
      groups.map_with_index do |(section, boxes), index|
        rows = boxes.map do |box|
          cells = [Table::Cell.new(box.code), Table::Cell.new(I18n.t(box.label_key))]
          if saved
            cells << amount_cell(box.computed)
            cells << amount_cell(box.amount)
            cells << Table::Cell.new(box.adjusted ? I18n.t("ui.vat_returns.adjusted_yes") : "")
          else
            cells << amount_cell(box.amount)
          end
          Table::Row.new(cells, box.total ? "pd-row-total" : "")
        end
        table = Table.new(I18n.t(section), columns, rows, request.path, id: "pd-vat-boxes-#{index}",
          empty_message: I18n.t("ui.vat_returns.no_boxes"))
        table.exportable = false
        Screen::Section.new(I18n.t(section), table: table)
      end
    end

    # Lignes d'un relevé (listing des clients, relevé intracommunautaire).
    def lines_section(view : Acc::VatReturnView) : Screen::Section?
      return unless form_listing?(view.form)
      intra = view.form == "be_intra_listing"
      columns = [
        Table::Column.new("name", I18n.t("ui.vat_returns.customer")),
        Table::Column.new("vat_number", I18n.t("ui.vat_returns.vat_number"), "mono"),
      ]
      columns << Table::Column.new("code", I18n.t("ui.vat_returns.intra_code"), "mono") if intra
      columns << Table::Column.new("amount", I18n.t("ui.vat_returns.base"), "amount")
      columns << Table::Column.new("vat", I18n.t("ui.vat_returns.vat"), "amount") unless intra
      rows = view.lines.map do |line|
        url = line.card_code.try { |code| card_url(code) }
        cells = [Table::Cell.new(line.name, url), Table::Cell.new(line.vat_number)]
        cells << Table::Cell.new(line.code.empty? ? "" : "#{line.code} — #{I18n.t("ui.vat_returns.intra_codes.#{line.code.downcase}")}", sort: line.code) if intra
        cells << amount_cell(line.amount)
        cells << amount_cell(line.vat) unless intra
        Table::Row.new(cells)
      end
      table = Table.new(I18n.t("ui.vat_returns.lines"), columns, rows, request.path, id: "pd-vat-lines",
        empty_message: I18n.t("ui.vat_returns.no_lines"))
      table.exportable = false
      Screen::Section.new(I18n.t("ui.vat_returns.lines"), table: table)
    end

    # Annexe 3310-A d'une CA3 ou d'une CA12 : ligne 14 taux par taux
    # (DECISIONS D-R5-006).
    def annex_section(view : Acc::VatReturnView) : Screen::Section?
      annex = view.annex_lines
      return if annex.empty?
      columns = [
        Table::Column.new("rate", I18n.t("ui.vat_returns.annex_rate"), "mono"),
        Table::Column.new("label", I18n.t("ui.vat_returns.annex_label")),
        Table::Column.new("amount", I18n.t("ui.vat_returns.base"), "amount"),
        Table::Column.new("vat", I18n.t("ui.vat_returns.vat"), "amount"),
      ]
      rows = annex.map do |line|
        Table::Row.new([Table::Cell.new(line.vat_number), Table::Cell.new(line.name), amount_cell(line.amount), amount_cell(line.vat)])
      end
      title = I18n.t("ui.vat_returns.annex")
      table = Table.new(title, columns, rows, request.path, id: "pd-vat-annex")
      table.exportable = false
      Screen::Section.new(title, table: table, note: I18n.t("ui.vat_returns.annex_note"))
    end

    def form_listing?(form : String) : Bool
      form_view(form).try(&.listing) || form.in?("be_client_listing", "be_intra_listing")
    end

    def return_url(view : Acc::VatReturnView) : String
      reverse("accounting:vat_return_show", id: view.id || id_param)
    end

    def return_title(view : Acc::VatReturnView) : String
      "#{form_name(view.form)} · #{period_label(view)}"
    end

    # Messages des erreurs du contrat (flash).
    def messages(errors : Array(Partiduo::Api::FieldError)) : String
      errors.map { |error| fmt.message(error) }.join(" ")
    end
  end

  # Préparation (`decl_tva.inc.php`, `choose_periode`) : critères, puis la
  # déclaration calculée sans être enregistrée (`preview_vat_return`, requête
  # de contrôle) et son enregistrement en brouillon.
  class VatPrepareHandler < VatScreenBase
    def get
      require!(MODULE, PERMISSION)
      form_errors = [] of {String, String}
      input = read_criteria(form_errors)
      filters = criteria_form(input)
      sections = [] of Screen::Section
      summary = nil
      if query("f") == "1" && form_errors.empty?
        result = Acc.preview_vat_return(current.actor, input)
        if view = result.value?
          summary = [
            Screen::Item.new(I18n.t("ui.vat_returns.form"), form_name(view.form)),
            Screen::Item.new(I18n.t("ui.vat_returns.period"), period_label(view)),
            Screen::Item.new(I18n.t("ui.vat_returns.exigibility"), exigibility_label(view.exigibility)),
          ]
          sections = box_sections(view, saved: false)
          lines_section(view).try { |section| sections << section }
          annex_section(view).try { |section| sections << section }
          save = post_action("ui.vat_returns.save_draft", "#{reverse("accounting:vat_return_create")}?#{URI::Params.encode(criteria_params)}",
            style: "primary", icon: "check")
          sections << Screen::Section.new(I18n.t("ui.vat_returns.next_step"), note: I18n.t("ui.vat_returns.save_help"),
            actions: [save])
        else
          filters.add_errors(result.errors, fmt)
        end
      end
      form_errors.each { |(name, message)| filters.add_error(name, message) }
      vat_page(I18n.t("accounting.menu.acc_vat_return"), "prepare", sections, filters: filters, summary: summary,
        intro: I18n.t("ui.vat_returns.prepare_intro"), status: filters.invalid ? 422 : 200)
    end

    def criteria_form(input : Acc::VatReturnInput) : Form
      form_options = forms.map { |form| option(form.form, form_name(form.form)) }
      periodicities = %w[month quarter year].map { |value| option(value, I18n.t("ui.vat_returns.periodicities.#{value}")) }
      numbers = (1..12).map { |value| option(value.to_s, value.to_s) }
      exigibilities = %w[rates operation payment].map { |value| option(value, exigibility_label(value)) }
      fields = [
        Form::Field.new("form", I18n.t("ui.vat_returns.form"), "select", input.form, options: form_options, required: true),
        Form::Field.new("year", I18n.t("ui.vat_returns.year_label"), value: query("year").presence || input.year.to_s, mono: true,
          required: true, maxlength: 4),
        Form::Field.new("periodicity", I18n.t("ui.vat_returns.periodicity"), "select", input.periodicity, options: periodicities,
          help: I18n.t("ui.vat_returns.periodicity_help")),
        Form::Field.new("number", I18n.t("ui.vat_returns.number"), "select", input.number.to_s, options: numbers,
          help: I18n.t("ui.vat_returns.number_help")),
        Form::Field.new("exigibility", I18n.t("ui.vat_returns.exigibility"), "select", input.exigibility, options: exigibilities,
          help: I18n.t("ui.vat_returns.exigibility_help")),
        Form::Field.new("date_from", I18n.t("ui.vat_returns.date_from"), value: query("date_from"), mono: true,
          help: I18n.t("ui.vat_returns.dates_help")),
        Form::Field.new("date_to", I18n.t("ui.vat_returns.date_to"), value: query("date_to"), mono: true),
        Form::Field.new("threshold", I18n.t("ui.vat_returns.threshold"), "number", query("threshold"), mono: true,
          help: I18n.t("ui.vat_returns.threshold_help")),
      ]
      Form.new([Form::Group.new(nil, fields)])
    end
  end

  # Enregistrement en brouillon (`create_vat_return`) : mêmes critères que
  # la préparation, repris de l'adresse.
  class VatReturnCreateHandler < VatScreenBase
    def post
      require!(MODULE, PERMISSION)
      form_errors = [] of {String, String}
      input = read_criteria(form_errors)
      back = "#{reverse("accounting:vat_return")}?#{URI::Params.encode(PersistentFilters.pick(request.query_params, CRITERIA).merge({"f" => "1"}))}"
      unless form_errors.empty?
        flash["danger"] = form_errors.map(&.[1]).join(" ")
        return go(back)
      end
      result = Acc.create_vat_return(current.actor, input)
      if view = result.value?
        flash["success"] = I18n.t("ui.vat_returns.created", name: form_name(view.form))
        return go(return_url(view))
      end
      flash["danger"] = messages(result.errors)
      go(back)
    end
  end

  # Historique (`list_tva.inc.php`) : déclarations enregistrées, filtres
  # par formulaire et par année, export CSV.
  class VatReturnsHandler < VatScreenBase
    def get
      require!(MODULE, PERMISSION)
      form = query("form").presence
      year = query("year").to_i?
      returns = Acc.vat_returns(current.actor, form: form, year: year)
      columns = [
        Table::Column.new("form", I18n.t("ui.vat_returns.form")),
        Table::Column.new("period", I18n.t("ui.vat_returns.period")),
        Table::Column.new("status", I18n.t("ui.vat_returns.status")),
        Table::Column.new("created", I18n.t("ui.vat_returns.created_at"), secondary: true),
        Table::Column.new("closed", I18n.t("ui.vat_returns.closed_at"), secondary: true),
        Table::Column.new("settlement", I18n.t("ui.vat_returns.settlement"), secondary: true),
      ]
      rows = returns.map do |view|
        Table::Row.new([
          Table::Cell.new(form_name(view.form), return_url(view)),
          Table::Cell.new(period_label(view), sort: date_key(view.date_from), csv: "#{date_key(view.date_from)} #{date_key(view.date_to)}"),
          Table::Cell.new(status_label(view.status)),
          Table::Cell.new(fmt.datetime(view.created_at), sort: view.created_at.try(&.to_rfc3339) || ""),
          Table::Cell.new(fmt.datetime(view.closed_at), sort: view.closed_at.try(&.to_rfc3339) || ""),
          Table::Cell.new(view.settlement_entry_id ? I18n.t("ui.vat_returns.settled") : "",
            entry_url(view.settlement_entry_id)),
        ], view.closed? ? "pd-row-closed" : "")
      end
      params = {} of String => String
      form.try { |value| params["form"] = value }
      year.try { |value| params["year"] = value.to_s }
      table = Table.new(I18n.t("ui.vat_returns.tabs.history"), columns, rows, reverse("accounting:vat_returns"), params,
        empty_message: I18n.t("ui.vat_returns.empty"), id: "pd-vat-returns")
      form_options = [option("", I18n.t("ui.vat_returns.all_forms"))] + forms.map { |item| option(item.form, form_name(item.form)) }
      filters = search_filters([
        Form::Field.new("form", I18n.t("ui.vat_returns.form"), "select", form || "", options: form_options),
        Form::Field.new("year", I18n.t("ui.vat_returns.year_label"), value: year.try(&.to_s) || "", mono: true, maxlength: 4),
      ])
      actions = [link_action("ui.vat_returns.new", reverse("accounting:vat_return"), "primary", "plus")]
      list_page(I18n.t("ui.vat_returns.history_title"), table, vat_crumbs, "ui.vat_returns.csv_name", actions,
        tabs: vat_tabs("history"), tabs_label: I18n.t("ui.vat_returns.tabs.label"), filters: filters)
    end

    private def entry_url(id : Int64?) : String?
      id.try { |value| reverse("accounting:entry", id: value) }
    end
  end

  # Une déclaration enregistrée : synthèse, cases par cadre (calculé,
  # déclaré, corrigé), relevé ; actions selon l'état (corriger, recalculer,
  # contrôler, clore, liquider, supprimer) et exports.
  class VatReturnHandler < VatScreenBase
    def get
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      sections = box_sections(view, saved: true)
      lines_section(view).try { |section| sections << section }
      annex_section(view).try { |section| sections << section }
      vat_page(return_title(view), nil, sections, crumbs: return_crumbs, actions: return_actions(view),
        summary: return_summary(view), status_tag: status_label(view.status))
    end

    def return_crumbs : Array(Screen::Crumb)
      vat_crumbs + [crumb("ui.vat_returns.tabs.history", reverse("accounting:vat_returns"))]
    end

    def return_summary(view : Acc::VatReturnView) : Array(Screen::Item)
      items = [
        Screen::Item.new(I18n.t("ui.vat_returns.form"), form_name(view.form)),
        Screen::Item.new(I18n.t("ui.vat_returns.period"), period_label(view)),
        Screen::Item.new(I18n.t("ui.vat_returns.exigibility"), exigibility_label(view.exigibility)),
        Screen::Item.new(I18n.t("ui.vat_returns.status"), status_label(view.status)),
        Screen::Item.new(I18n.t("ui.vat_returns.created_at"), fmt.datetime(view.created_at)),
        Screen::Item.new(I18n.t("ui.vat_returns.closed_at"), fmt.datetime(view.closed_at)),
      ]
      view.threshold.try { |value| items << Screen::Item.new(I18n.t("ui.vat_returns.threshold"), fmt.amount(value), mono: true) }
      if view.form == "be_client_listing"
        items << Screen::Item.new(I18n.t("ui.vat_returns.client_listing_nihil"), yes_no(view.client_listing_nihil))
      end
      if view.form == "be_periodic"
        items << Screen::Item.new(I18n.t("ui.vat_returns.ask_restitution"), yes_no(view.ask_restitution))
      end
      view.settlement_entry_id.try do |entry|
        items << Screen::Item.new(I18n.t("ui.vat_returns.settlement"), I18n.t("ui.vat_returns.settlement_entry", id: entry.to_s),
          reverse("accounting:entry", id: entry))
      end
      items
    end

    def return_actions(view : Acc::VatReturnView) : Array(Screen::Action)
      id = id_param
      actions = [] of Screen::Action
      if view.closed?
        if settles?(view) && view.settlement_entry_id.nil?
          actions << link_action("ui.vat_returns.settle", reverse("accounting:vat_return_settle", id: id), "primary", "check")
        end
      else
        actions << link_action("ui.vat_returns.close", reverse("accounting:vat_return_close", id: id), "primary", "lock")
        actions << link_action("ui.vat_returns.edit", reverse("accounting:vat_return_edit", id: id))
        actions << post_action("ui.vat_returns.recompute", reverse("accounting:vat_return_recompute", id: id))
      end
      actions << link_action("ui.vat_returns.control", reverse("accounting:vat_return_control", id: id), icon: "search")
      file = reverse("accounting:vat_return_file", id: id)
      actions << link_action("ui.vat_returns.export_xml", "#{file}?format=xml", icon: "download") if view.regime == "be"
      actions << link_action("ui.table.export_csv", "#{file}?format=csv", icon: "download")
      actions << link_action("ui.reports.export_pdf", "#{file}?format=pdf", icon: "printer")
      unless view.closed?
        actions << post_action("ui.forms.delete", reverse("accounting:vat_return_delete", id: id), "ui.vat_returns.delete_confirm", "danger")
      end
      actions
    end

    def settles?(view : Acc::VatReturnView) : Bool
      form_view(view.form).try(&.settles) || false
    end
  end

  # Contrôle (`display_detail_amount`) : pour chaque case, l'apport de chaque
  # règle relu dans les écritures ; d'un brouillon, les cases dont le calcul
  # a changé depuis l'enregistrement (écritures passées ou modifiées).
  class VatReturnControlHandler < VatScreenBase
    def get
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      details = Acc.vat_return_details(current.actor, id_param)
      warnings = [] of String
      changed = view.closed? ? [] of String : changed_boxes(view)
      unless changed.empty?
        warnings << I18n.t("ui.vat_returns.stale", boxes: changed.join(", "))
      end
      adjusted = view.boxes.select(&.adjusted)
      unless adjusted.empty?
        warnings << I18n.t("ui.vat_returns.adjusted_boxes", boxes: adjusted.map(&.code).join(", "))
      end
      sections = [comparison_section(view, changed), details_section(details)]
      actions = [link_action("ui.vat_returns.back", return_url(view))]
      unless view.closed? || changed.empty?
        actions << post_action("ui.vat_returns.recompute", reverse("accounting:vat_return_recompute", id: id_param),
          style: "primary")
      end
      crumbs = vat_crumbs + [crumb("ui.vat_returns.tabs.history", reverse("accounting:vat_returns")),
                             Screen::Crumb.new(return_title(view), return_url(view))]
      vat_page(I18n.t("ui.vat_returns.control_title", name: form_name(view.form)), nil, sections, crumbs: crumbs,
        actions: actions, warnings: warnings, intro: I18n.t("ui.vat_returns.control_intro"),
        status_tag: status_label(view.status))
    end

    # Cases dont le montant calculé aujourd'hui diffère de celui du
    # brouillon (même calcul du cœur, `preview_vat_return`).
    private def changed_boxes(view : Acc::VatReturnView) : Array(String)
      # Bornes libres : CA12 seulement (exercice décalé), refusées ailleurs.
      free = view.form == "fr_ca12"
      input = Acc::VatReturnInput.new(form: view.form, year: view.year, periodicity: view.periodicity, number: view.number,
        date_from: free ? view.date_from : nil, date_to: free ? view.date_to : nil, exigibility: view.exigibility,
        threshold: view.threshold)
      preview = Acc.preview_vat_return(current.actor, input).value? || return [] of String
      codes = view.boxes.compact_map do |box|
        now = preview.box(box.code).try(&.computed) || BigDecimal.new(0)
        box.code unless now == box.computed
      end
      codes << I18n.t("ui.vat_returns.lines") unless same_lines?(view, preview)
      codes
    end

    private def same_lines?(left : Acc::VatReturnView, right : Acc::VatReturnView) : Bool
      key = ->(view : Acc::VatReturnView) { view.lines.map { |line| {line.vat_number, line.code, line.amount, line.vat} }.sort! }
      key.call(left) == key.call(right)
    end

    private def comparison_section(view : Acc::VatReturnView, changed : Array(String)) : Screen::Section
      columns = [
        Table::Column.new("code", I18n.t("ui.vat_returns.box"), "mono", sortable: false),
        Table::Column.new("label", I18n.t("ui.vat_returns.box_label"), sortable: false),
        Table::Column.new("computed", I18n.t("ui.vat_returns.computed"), "amount", sortable: false),
        Table::Column.new("amount", I18n.t("ui.vat_returns.declared"), "amount", sortable: false),
        Table::Column.new("state", I18n.t("ui.vat_returns.state"), sortable: false),
      ]
      rows = view.boxes.map do |box|
        state = [] of String
        state << I18n.t("ui.vat_returns.adjusted_yes") if box.adjusted
        state << I18n.t("ui.vat_returns.changed") if changed.includes?(box.code)
        Table::Row.new([
          Table::Cell.new(box.code), Table::Cell.new(I18n.t(box.label_key)),
          amount_cell(box.computed), amount_cell(box.amount), Table::Cell.new(state.join(", ")),
        ], state.empty? ? "" : "pd-row-subtotal")
      end
      table = Table.new(I18n.t("ui.vat_returns.comparison"), columns, rows, request.path, id: "pd-vat-comparison",
        empty_message: I18n.t("ui.vat_returns.no_boxes"))
      table.exportable = false
      Screen::Section.new(I18n.t("ui.vat_returns.comparison"), table: table)
    end

    private def details_section(details : Array(Acc::VatDetailView)) : Screen::Section
      columns = [
        Table::Column.new("box", I18n.t("ui.vat_returns.box"), "mono", sortable: false),
        Table::Column.new("rule", I18n.t("ui.vat_returns.rule"), sortable: false),
        Table::Column.new("lines", I18n.t("ui.vat_returns.movements"), "amount", secondary: true, sortable: false),
        Table::Column.new("amount", I18n.t("ui.vat_returns.amount"), "amount", sortable: false),
      ]
      rows = details.map do |detail|
        Table::Row.new([
          Table::Cell.new(detail.box),
          Table::Cell.new(VatRuleText.describe(detail.vat_rate_code, detail.ledger_kind, detail.ledger_code, detail.accounts,
            detail.excluded_accounts, detail.source, detail.sign, detail.operation)),
          Table::Cell.new(detail.lines.to_s, sort: BigDecimal.new(detail.lines)),
          amount_cell(detail.amount),
        ])
      end
      table = Table.new(I18n.t("ui.vat_returns.details"), columns, rows, request.path, id: "pd-vat-details",
        empty_message: I18n.t("ui.vat_returns.no_details"))
      table.exportable = false
      Screen::Section.new(I18n.t("ui.vat_returns.details"), table: table)
    end
  end

  # Description lisible d'une règle de calcul d'une case.
  module VatRuleText
    def self.describe(rate : String?, ledger_kind : String?, ledger_code : String?, accounts : String, excluded : String,
                      source : String, sign : String, operation : String) : String
      parts = [I18n.t("ui.vat_returns.sources.#{source}")]
      parts << (rate ? I18n.t("ui.vat_returns.rule_rate", code: rate) : I18n.t("ui.vat_returns.rule_all_rates")) unless source == "balance"
      if ledger_code
        parts << I18n.t("ui.vat_returns.rule_ledger", code: ledger_code)
      elsif ledger_kind
        parts << I18n.t("ui.vat_returns.rule_ledger_kind", kind: I18n.t("accounting.ledger_kinds.#{ledger_kind}"))
      end
      parts << I18n.t("ui.vat_returns.rule_accounts", accounts: accounts) unless accounts.empty?
      parts << I18n.t("ui.vat_returns.rule_excluded", accounts: excluded) unless excluded.empty?
      parts << I18n.t("ui.vat_returns.signs.#{sign}") unless sign == "all"
      parts << I18n.t("ui.vat_returns.operations.subtract") if operation == "subtract"
      parts.join(" · ")
    end
  end

  # Correction des cases d'un brouillon (`update_vat_return`) : montant
  # déclaré de chaque case corrigeable (vide : montant calculé),
  # indicateurs du formulaire belge.
  class VatReturnEditHandler < VatScreenBase
    def get
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      return closed_redirect(view) if view.closed?
      show(view, edit_form(view))
    end

    def post
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      return closed_redirect(view) if view.closed?
      form_errors = [] of {String, String}
      adjustments = read_adjustments(view, form_errors)
      unless form_errors.empty?
        return show(view, refused(view, form_errors), 422)
      end
      nihil = view.form == "be_client_listing" ? checkbox("client_listing_nihil") : nil
      restitution = view.form == "be_periodic" ? checkbox("ask_restitution") : nil
      input = Acc::VatReturnUpdateInput.new(adjustments: adjustments, client_listing_nihil: nihil, ask_restitution: restitution)
      result = Acc.update_vat_return(current.actor, id_param, input)
      if result.success?
        flash["success"] = I18n.t("ui.vat_returns.updated")
        return go(return_url(view))
      end
      errors = result.errors.map do |error|
        # `adjustments[i].amount` : la case de la i-ème correction envoyée.
        if match = error.field.match(/\Aadjustments\[(\d+)\]/)
          code = adjustments[match[1].to_i]?.try(&.code)
          code ? error.copy_with(field: field_name(code)) : error
        else
          error
        end
      end
      show(view, refused(view, form_errors).add_errors(errors, fmt), 422)
    end

    # Corrections envoyées : case vidée (retour au calculé), montant saisi
    # différent du calculé ; montant illisible : erreur sous la case.
    private def read_adjustments(view : Acc::VatReturnView, form_errors : Array({String, String})) : Array(Acc::VatAdjustment)
      adjustments = [] of Acc::VatAdjustment
      editable(view).each do |box|
        name = field_name(box.code)
        text = field(name)
        if text.empty?
          adjustments << Acc::VatAdjustment.new(box.code, nil) if box.adjusted
        elsif value = fmt.parse_decimal(text)
          adjustments << Acc::VatAdjustment.new(box.code, value) if box.adjusted || value != box.computed
        else
          form_errors << {name, I18n.t("ui.forms.invalid_number")}
        end
      end
      adjustments
    end

    private def closed_redirect(view : Acc::VatReturnView) : Marten::HTTP::Response
      flash["warning"] = I18n.t("accounting.errors.vat_return.closed")
      go(return_url(view))
    end

    private def editable(view : Acc::VatReturnView) : Array(Acc::VatBoxView)
      view.boxes.reject(&.total)
    end

    private def field_name(code : String) : String
      "box_#{code}"
    end

    # Formulaire : champs remplis des valeurs envoyées, erreurs sous leur case.
    private def refused(view : Acc::VatReturnView, form_errors : Array({String, String})) : Form
      form = edit_form(view)
      form.fields.each { |item| item.value = field(item.name) unless item.type == "checkbox" }
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form
    end

    private def edit_form(view : Acc::VatReturnView) : Form
      groups = [] of Form::Group
      editable(view).group_by(&.section_key).each do |section, boxes|
        fields = boxes.map do |box|
          Form::Field.new(field_name(box.code), "#{box.code} — #{I18n.t(box.label_key)}", "number",
            box.adjusted ? fmt.input_number(box.amount, 2) : "", mono: true, placeholder: fmt.amount(box.computed),
            help: I18n.t("ui.vat_returns.computed_help", amount: fmt.amount(box.computed)))
        end
        groups << Form::Group.new(I18n.t(section), fields)
      end
      flags = [] of Form::Field
      if view.form == "be_client_listing"
        flags << Form::Field.new("client_listing_nihil", I18n.t("ui.vat_returns.client_listing_nihil"), "checkbox",
          view.client_listing_nihil ? "1" : "")
      end
      if view.form == "be_periodic"
        flags << Form::Field.new("ask_restitution", I18n.t("ui.vat_returns.ask_restitution"), "checkbox",
          view.ask_restitution ? "1" : "")
      end
      groups << Form::Group.new(I18n.t("ui.vat_returns.options"), flags) unless flags.empty?
      Form.new(groups)
    end

    private def show(view : Acc::VatReturnView, form : Form, status : Int32? = nil) : Marten::HTTP::Response
      crumbs = vat_crumbs + [Screen::Crumb.new(return_title(view), return_url(view))]
      form_page(I18n.t("ui.vat_returns.edit_title", name: form_name(view.form)), crumbs, form,
        reverse("accounting:vat_return_edit", id: id_param), I18n.t("ui.forms.save"), return_url(view),
        intro: I18n.t("ui.vat_returns.edit_intro"), status: status)
    end
  end

  # Commandes simples d'une déclaration : recalcul, suppression.
  class VatReturnRecomputeHandler < VatScreenBase
    def post
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      result = Acc.recompute_vat_return(current.actor, id_param)
      if result.success?
        flash["success"] = I18n.t("ui.vat_returns.recomputed")
      else
        flash["danger"] = messages(result.errors)
      end
      go(return_url(view))
    end
  end

  class VatReturnDeleteHandler < VatScreenBase
    def post
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      result = Acc.delete_vat_return(current.actor, id_param)
      if result.success?
        flash["success"] = I18n.t("ui.vat_returns.deleted", name: form_name(view.form))
        return go(reverse("accounting:vat_returns"))
      end
      flash["danger"] = messages(result.errors)
      go(return_url(view))
    end
  end

  # Écriture de liquidation (`propose_form`) : journal d'opérations
  # diverses, date, comptes de dette et de créance ; vides : valeurs par
  # défaut du cœur.
  abstract class VatSettlementScreen < VatScreenBase
    def settlement_fields(view : Acc::VatReturnView) : Array(Form::Field)
      ledgers = begin
        Acc.ledgers(current.actor, kind: Acc::LedgerKind::Misc, enabled_only: true)
      rescue Partiduo::Api::AccessDenied
        [] of Acc::LedgerView
      end
      options = [option("", I18n.t("ui.vat_returns.default_ledger"))] + ledgers.map { |ledger| option(ledger.id.to_s, "#{ledger.code} · #{ledger.name}") }
      [
        Form::Field.new("ledger_id", I18n.t("ui.entries.ledger"), "select", field("ledger_id"), options: options),
        Form::Field.new("date", I18n.t("ui.vat_returns.settlement_date"), value: field("date").presence || fmt.date(view.date_to), mono: true),
        Form::Field.new("payable_account", I18n.t("ui.vat_returns.payable_account"), value: field("payable_account"), mono: true,
          help: I18n.t("ui.vat_returns.payable_help")),
        Form::Field.new("receivable_account", I18n.t("ui.vat_returns.receivable_account"), value: field("receivable_account"), mono: true,
          help: I18n.t("ui.vat_returns.receivable_help")),
      ]
    end

    def read_settlement(form_errors : Array({String, String})) : Acc::VatSettlementInput
      day = nil
      unless (text = field("date")).empty?
        day = fmt.parse_short_date(text, reference_day)
        form_errors << {"date", I18n.t("ui.forms.invalid_date")} unless day
      end
      Acc::VatSettlementInput.new(ledger_id: field("ledger_id").to_i64?, date: day,
        payable_account: field("payable_account").presence, receivable_account: field("receivable_account").presence)
    end

    # Erreurs du contrat `settlement.<champ>` rangées sous le champ.
    def settlement_errors(errors : Array(Partiduo::Api::FieldError)) : Array(Partiduo::Api::FieldError)
      errors.map { |error| error.field.starts_with?("settlement.") ? error.copy_with(field: error.field.lchop("settlement.")) : error }
    end

    def show(view : Acc::VatReturnView, form : Form, title_key : String, action : String, submit_key : String,
             intro_key : String, status : Int32? = nil) : Marten::HTTP::Response
      crumbs = vat_crumbs + [Screen::Crumb.new(return_title(view), return_url(view))]
      form_page(I18n.t(title_key, name: form_name(view.form)), crumbs, form, action, I18n.t(submit_key), return_url(view),
        intro: I18n.t(intro_key, period: period_label(view)), status: status)
    end
  end

  # Clôture (`close_vat_return`) : la déclaration est figée ; avec
  # l'écriture de liquidation si elle est demandée.
  class VatReturnCloseHandler < VatSettlementScreen
    def get
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      return go(return_url(view)) if view.closed?
      render_form(view, close_form(view, true))
    end

    def post
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      return go(return_url(view)) if view.closed?
      settle = settles?(view) && checkbox("settle")
      form_errors = [] of {String, String}
      settlement = read_settlement(form_errors)
      unless form_errors.empty?
        form = close_form(view, settle)
        form_errors.each { |(name, message)| form.add_error(name, message) }
        return render_form(view, form, 422)
      end
      result = Acc.close_vat_return(current.actor, id_param, settle ? settlement : nil)
      if closed = result.value?
        flash["success"] = closed.settlement_entry_id ? I18n.t("ui.vat_returns.closed_settled") : I18n.t("ui.vat_returns.closed")
        return go(return_url(closed))
      end
      render_form(view, close_form(view, settle).add_errors(settlement_errors(result.errors), fmt), 422)
    end

    private def settles?(view : Acc::VatReturnView) : Bool
      form_view(view.form).try(&.settles) || false
    end

    private def close_form(view : Acc::VatReturnView, settle : Bool) : Form
      groups = [] of Form::Group
      if settles?(view)
        fields = [Form::Field.new("settle", I18n.t("ui.vat_returns.settle_now"), "checkbox", settle ? "1" : "",
          help: I18n.t("ui.vat_returns.settle_help"))]
        groups << Form::Group.new(I18n.t("ui.vat_returns.settlement"), fields + settlement_fields(view))
      else
        groups << Form::Group.new(nil, [Form::Field.new("confirm", "", "hidden", "1")])
      end
      Form.new(groups)
    end

    private def render_form(view : Acc::VatReturnView, form : Form, status : Int32? = nil) : Marten::HTTP::Response
      show(view, form, "ui.vat_returns.close_title", reverse("accounting:vat_return_close", id: id_param),
        "ui.vat_returns.close", "ui.vat_returns.close_intro", status)
    end
  end

  # Liquidation d'une déclaration close qui n'en a pas (`settle_vat_return`).
  class VatReturnSettleHandler < VatSettlementScreen
    def get
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      render_form(view, Form.new([Form::Group.new(nil, settlement_fields(view))]))
    end

    def post
      require!(MODULE, PERMISSION)
      view = Acc.vat_return(current.actor, id_param)
      form_errors = [] of {String, String}
      settlement = read_settlement(form_errors)
      form = Form.new([Form::Group.new(nil, settlement_fields(view))])
      unless form_errors.empty?
        form_errors.each { |(name, message)| form.add_error(name, message) }
        return render_form(view, form, 422)
      end
      result = Acc.settle_vat_return(current.actor, id_param, settlement)
      if settled = result.value?
        flash["success"] = I18n.t("ui.vat_returns.settled_message")
        return go(return_url(settled))
      end
      render_form(view, form.add_errors(settlement_errors(result.errors), fmt), 422)
    end

    private def render_form(view : Acc::VatReturnView, form : Form, status : Int32? = nil) : Marten::HTTP::Response
      show(view, form, "ui.vat_returns.settle_title", reverse("accounting:vat_return_settle", id: id_param),
        "ui.vat_returns.settle", "ui.vat_returns.settle_intro", status)
    end
  end

  # Exports d'une déclaration : XML Intervat (formulaires belges), CSV, PDF,
  # produits par le cœur.
  class VatReturnFileHandler < VatScreenBase
    def get
      require!(MODULE, PERMISSION)
      format = case query("format")
               when "xml" then Acc::VatFileFormat::Xml
               when "csv" then Acc::VatFileFormat::Csv
               when "pdf" then Acc::VatFileFormat::Pdf
               end
      raise Partiduo::Api::NotFound.new("vat_return_file", id_param) unless format
      result = Acc.vat_return_file(current.actor, id_param, format)
      if file = result.value?
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
        return response
      end
      flash["danger"] = messages(result.errors)
      go(reverse("accounting:vat_return_show", id: id_param))
    end
  end

  # Paramètres (`tva_param.inc.php`) : mandataire des fichiers Intervat
  # (formulaire) et règles de calcul des cases de chaque régime (tableau,
  # une case par ligne, modifiable).
  class VatSettingsHandler < VatScreenBase
    SETTINGS_FIELDS = %w[representative_name representative_id representative_id_type representative_issued_by
      representative_street representative_postcode representative_city representative_country_code
      representative_email representative_phone]

    def get
      require!(MODULE, PERMISSION)
      settings = Acc.vat_settings(current.actor)
      show(settings_form(settings_input(settings)))
    end

    def post
      require!(MODULE, PERMISSION)
      input = Acc::VatSettingsInput.new(
        representative_id: field("representative_id"), representative_id_type: field("representative_id_type"),
        representative_issued_by: field("representative_issued_by"), representative_name: field("representative_name"),
        representative_street: field("representative_street"), representative_postcode: field("representative_postcode"),
        representative_city: field("representative_city"), representative_country_code: field("representative_country_code"),
        representative_email: field("representative_email"), representative_phone: field("representative_phone"),
      )
      result = Acc.update_vat_settings(current.actor, input)
      if result.success?
        flash["success"] = I18n.t("ui.vat_returns.settings_saved")
        return go(reverse("accounting:vat_settings"))
      end
      show(settings_form(input).add_errors(result.errors, fmt), 422)
    end

    private def settings_input(view : Acc::VatSettingsView) : Acc::VatSettingsInput
      Acc::VatSettingsInput.new(
        representative_id: view.representative_id, representative_id_type: view.representative_id_type,
        representative_issued_by: view.representative_issued_by, representative_name: view.representative_name,
        representative_street: view.representative_street, representative_postcode: view.representative_postcode,
        representative_city: view.representative_city, representative_country_code: view.representative_country_code,
        representative_email: view.representative_email, representative_phone: view.representative_phone,
      )
    end

    private def settings_form(input : Acc::VatSettingsInput) : Form
      values = {
        "representative_name"         => input.representative_name,
        "representative_id"           => input.representative_id,
        "representative_id_type"      => input.representative_id_type,
        "representative_issued_by"    => input.representative_issued_by,
        "representative_street"       => input.representative_street,
        "representative_postcode"     => input.representative_postcode,
        "representative_city"         => input.representative_city,
        "representative_country_code" => input.representative_country_code,
        "representative_email"        => input.representative_email,
        "representative_phone"        => input.representative_phone,
      }
      fields = SETTINGS_FIELDS.map do |name|
        mono = name.in?("representative_id", "representative_id_type", "representative_issued_by", "representative_country_code",
          "representative_postcode")
        type = name == "representative_email" ? "email" : "text"
        help = case name
               when "representative_id_type"   then I18n.t("ui.vat_returns.settings_fields.id_type_help")
               when "representative_issued_by" then I18n.t("ui.vat_returns.settings_fields.country_help")
               end
        Form::Field.new(name, I18n.t("ui.vat_returns.settings_fields.#{name}"), type, values[name], mono: mono, help: help)
      end
      Form.new([Form::Group.new(I18n.t("ui.vat_returns.representative"), fields)])
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      set_form(form, reverse("accounting:vat_settings"), I18n.t("ui.forms.save"), title: I18n.t("ui.vat_returns.representative"))
      vat_page(I18n.t("ui.vat_returns.settings_title"), "settings", rules_sections, intro: I18n.t("ui.vat_returns.settings_intro"),
        status: status)
    end

    # Une rubrique par régime des formulaires proposés : chaque case réglée
    # et ses règles.
    private def rules_sections : Array(Screen::Section)
      forms.map(&.regime).uniq!.map do |regime|
        rules = Acc.vat_box_rules(current.actor, regime)
        by_box = rules.group_by(&.box)
        labels = {} of String => String
        forms.select(&.regime.==(regime)).each do |form|
          form.boxes.each { |box| labels[box.code] ||= I18n.t(box.label_key) if box.ruled }
        end
        codes = labels.keys
        by_box.each_key { |code| codes << code unless codes.includes?(code) }
        columns = [
          Table::Column.new("box", I18n.t("ui.vat_returns.box"), "mono", sortable: false),
          Table::Column.new("label", I18n.t("ui.vat_returns.box_label"), sortable: false),
          Table::Column.new("rules", I18n.t("ui.vat_returns.rules"), sortable: false),
          Table::Column.new("actions", "", "actions"),
        ]
        rows = codes.map do |code|
          text = (by_box[code]? || [] of Acc::VatBoxRuleView).map do |rule|
            VatRuleText.describe(rule.vat_rate_code, rule.ledger_kind, rule.ledger_code, rule.accounts, rule.excluded_accounts,
              rule.source, rule.sign, rule.operation)
          end
          Table::Row.new([
            Table::Cell.new(code), Table::Cell.new(labels[code]? || ""),
            Table::Cell.new(text.empty? ? I18n.t("ui.vat_returns.no_rules") : text.join(" ; ")),
            Table::Cell.new("", actions: [link_action("ui.forms.edit", reverse("accounting:vat_rules", regime: regime, box: code), "small")]),
          ])
        end
        table = Table.new(I18n.t("ui.vat_returns.rules_title", regime: regime.upcase), columns, rows, request.path,
          id: "pd-vat-rules-#{regime}", empty_message: I18n.t("ui.vat_returns.no_rules"))
        table.exportable = false
        default = rules.any?(&.default) || rules.empty?
        actions = default ? nil : [post_action("ui.vat_returns.reset_rules", reverse("accounting:vat_rules_reset", regime: regime),
          "ui.vat_returns.reset_confirm", "danger")]
        Screen::Section.new(I18n.t("ui.vat_returns.rules_title", regime: regime.upcase), table: table,
          note: default ? I18n.t("ui.vat_returns.default_rules") : nil, actions: actions)
      end
    end
  end

  # Règles de calcul d'une case (`parameter_chld`) : une ligne par règle,
  # une ligne vide pour en ajouter, case « retirer » ; tout est remplacé
  # d'un bloc (`set_vat_box_rules`).
  class VatRulesHandler < VatScreenBase
    RULE_FIELDS = %w[vat_rate_code ledger_kind ledger_code accounts excluded_accounts source sign operation]

    def get
      require!(MODULE, PERMISSION)
      regime, box = params["regime"].to_s, params["box"].to_s
      rules = Acc.vat_box_rules(current.actor, regime).select(&.box.==(box))
      inputs = rules.map do |rule|
        Acc::VatBoxRuleInput.new(vat_rate_code: rule.vat_rate_code, ledger_kind: rule.ledger_kind, ledger_code: rule.ledger_code,
          accounts: rule.accounts, excluded_accounts: rule.excluded_accounts, source: rule.source, sign: rule.sign,
          operation: rule.operation)
      end
      show(regime, box, rules_form(inputs + [Acc::VatBoxRuleInput.new]))
    end

    def post
      require!(MODULE, PERMISSION)
      regime, box = params["regime"].to_s, params["box"].to_s
      count = field("count").to_i? || 0
      all = (0...Math.min(count, 100)).map { |index| {index, read_rule(index)} }
      kept = all.select { |(index, rule)| field("rules[#{index}].remove") != "1" && !blank?(rule) }
      result = Acc.set_vat_box_rules(current.actor, regime, box, kept.map(&.[1]))
      if result.success?
        flash["success"] = I18n.t("ui.vat_returns.rules_saved", box: box)
        return go(reverse("accounting:vat_settings"))
      end
      # `rules[k]` : k-ième règle envoyée → sa ligne dans le formulaire.
      errors = result.errors.map do |error|
        if match = error.field.match(/\Arules\[(\d+)\](.*)\z/)
          row = kept[match[1].to_i]?.try(&.[0])
          row ? error.copy_with(field: "rules[#{row}]#{match[2]}") : error
        else
          error
        end
      end
      form = rules_form(all.map(&.[1]))
      form.add_errors(errors, fmt)
      show(regime, box, form, 422)
    end

    # Ligne vide (celle ajoutée pour une nouvelle règle) : aucun filtre et
    # source, signe, opération par défaut. Une règle sans filtre mais d'une
    # autre source (« toute la TVA déductible ») est gardée.
    private def blank?(rule : Acc::VatBoxRuleInput) : Bool
      rule.vat_rate_code.nil? && rule.ledger_kind.nil? && rule.ledger_code.nil? && rule.accounts.strip.empty? &&
        rule.excluded_accounts.strip.empty? && rule.source == "base" && rule.sign == "all" && rule.operation == "add"
    end

    private def read_rule(index : Int32) : Acc::VatBoxRuleInput
      get = ->(name : String) { field("rules[#{index}].#{name}") }
      Acc::VatBoxRuleInput.new(vat_rate_code: get.call("vat_rate_code").presence, ledger_kind: get.call("ledger_kind").presence,
        ledger_code: get.call("ledger_code").presence, accounts: get.call("accounts"),
        excluded_accounts: get.call("excluded_accounts"), source: get.call("source").presence || "base",
        sign: get.call("sign").presence || "all", operation: get.call("operation").presence || "add")
    end

    private def rules_form(rules : Array(Acc::VatBoxRuleInput)) : Form
      rates = begin
        Partiduo::Api::Vat.rates(current.actor, include_disabled: true).map { |rate| option(rate.code, "#{rate.code} · #{rate.label}") }
      rescue Partiduo::Api::AccessDenied
        [] of Form::Option
      end
      ledgers = begin
        Acc.ledgers(current.actor).map { |ledger| option(ledger.code, "#{ledger.code} · #{ledger.name}") }
      rescue Partiduo::Api::AccessDenied
        [] of Form::Option
      end
      rate_options = [option("", I18n.t("ui.vat_returns.rule_all_rates"))] + rates
      kind_options = [option("", I18n.t("ui.reports.all_ledger_kinds"))] +
                     %w[purchase sale financial misc].map { |kind| option(kind, I18n.t("accounting.ledger_kinds.#{kind}")) }
      ledger_options = [option("", I18n.t("ui.reports.all_ledgers"))] + ledgers
      sources = %w[base deductible collected balance].map { |value| option(value, I18n.t("ui.vat_returns.sources.#{value}")) }
      signs = %w[all positive negative].map { |value| option(value, I18n.t("ui.vat_returns.signs.#{value}")) }
      operations = %w[add subtract].map { |value| option(value, I18n.t("ui.vat_returns.operations.#{value}")) }
      groups = rules.map_with_index do |rule, index|
        name = ->(field : String) { "rules[#{index}].#{field}" }
        fields = [
          Form::Field.new(name.call("source"), I18n.t("ui.vat_returns.source"), "select", rule.source, options: sources),
          Form::Field.new(name.call("vat_rate_code"), I18n.t("ui.vat_returns.rate"), "select", rule.vat_rate_code || "", options: rate_options),
          Form::Field.new(name.call("ledger_kind"), I18n.t("ui.reports.ledger_kind"), "select", rule.ledger_kind || "", options: kind_options),
          Form::Field.new(name.call("ledger_code"), I18n.t("ui.entries.ledger"), "select", rule.ledger_code || "", options: ledger_options),
          Form::Field.new(name.call("accounts"), I18n.t("ui.vat_returns.accounts"), value: rule.accounts, mono: true,
            help: I18n.t("ui.vat_returns.accounts_help")),
          Form::Field.new(name.call("excluded_accounts"), I18n.t("ui.vat_returns.excluded_accounts"), value: rule.excluded_accounts, mono: true),
          Form::Field.new(name.call("sign"), I18n.t("ui.vat_returns.sign"), "select", rule.sign, options: signs),
          Form::Field.new(name.call("operation"), I18n.t("ui.vat_returns.operation"), "select", rule.operation, options: operations),
          Form::Field.new(name.call("remove"), I18n.t("ui.vat_returns.remove_rule"), "checkbox", ""),
        ]
        legend = index == rules.size - 1 && blank?(rule) ? I18n.t("ui.vat_returns.new_rule") : I18n.t("ui.vat_returns.rule_number", number: (index + 1).to_s)
        Form::Group.new(legend, fields)
      end
      groups << Form::Group.new(nil, [Form::Field.new("count", "", "hidden", rules.size.to_s)])
      Form.new(groups)
    end

    private def show(regime : String, box : String, form : Form, status : Int32? = nil) : Marten::HTTP::Response
      crumbs = vat_crumbs + [crumb("ui.vat_returns.tabs.settings", reverse("accounting:vat_settings"))]
      form_page(I18n.t("ui.vat_returns.rules_edit_title", box: box, regime: regime.upcase), crumbs, form,
        reverse("accounting:vat_rules", regime: regime, box: box), I18n.t("ui.forms.save"), reverse("accounting:vat_settings"),
        intro: I18n.t("ui.vat_returns.rules_intro"), status: status)
    end
  end

  # Retour au paramétrage par défaut d'un régime.
  class VatRulesResetHandler < VatScreenBase
    def post
      require!(MODULE, PERMISSION)
      result = Acc.reset_vat_box_rules(current.actor, params["regime"].to_s)
      if result.success?
        flash["success"] = I18n.t("ui.vat_returns.rules_reset")
      else
        flash["danger"] = messages(result.errors)
      end
      go(reverse("accounting:vat_settings"))
    end
  end
end
