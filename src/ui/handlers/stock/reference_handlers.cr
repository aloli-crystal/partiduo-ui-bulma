# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Dépôts (menu `stock:repositories`, successeur de `stock_cfg.inc.php` et
  # `stock_repository`) : liste, consultation, création, modification,
  # suppression ; dépôt par défaut des mouvements automatiques.
  abstract class RepositoryScreen < StockScreen
    def crumbs : Array(Screen::Crumb)
      stock_crumbs("stock.menu.stock_repositories", reverse("stock:repositories"))
    end

    def repository_form(input : Stk::RepositoryInput) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.stock.repository_name"), value: input.name, required: true, maxlength: 100, wide: true),
        Form::Field.new("address", I18n.t("ui.stock.address"), "textarea", input.address, wide: true),
        Form::Field.new("city", I18n.t("ui.stock.city"), value: input.city, maxlength: 100),
        Form::Field.new("country_code", I18n.t("ui.stock.country_code"), value: input.country_code, mono: true, maxlength: 2,
          help: I18n.t("ui.stock.country_code_help")),
        Form::Field.new("phone", I18n.t("ui.stock.phone"), value: input.phone, maxlength: 40),
      ])])
    end

    def read_repository : Stk::RepositoryInput
      Stk::RepositoryInput.new(name: field("name"), address: field("address", strip: false).strip, city: field("city"),
        country_code: field("country_code").upcase, phone: field("phone"))
    end

    def to_input(repository : Stk::RepositoryView) : Stk::RepositoryInput
      Stk::RepositoryInput.new(repository.name, repository.address, repository.city, repository.country_code, repository.phone)
    end
  end

  class StockRepositoriesHandler < RepositoryScreen
    def get
      columns = [
        Table::Column.new("name", I18n.t("ui.stock.repository_name")),
        Table::Column.new("city", I18n.t("ui.stock.city")),
        Table::Column.new("country", I18n.t("ui.stock.country_code"), "mono", secondary: true),
        Table::Column.new("phone", I18n.t("ui.stock.phone"), secondary: true),
        Table::Column.new("default", I18n.t("ui.stock.default_repository")),
        Table::Column.new("movements", I18n.t("ui.stock.movements_count"), "amount"),
      ]
      rows = repositories.map do |repository|
        Table::Row.new([
          Table::Cell.new(repository.name, repository_url(repository.id)),
          Table::Cell.new(repository.city),
          Table::Cell.new(repository.country_code),
          Table::Cell.new(repository.phone),
          Table::Cell.new(repository.default ? I18n.t("ui.forms.answer_yes") : ""),
          Table::Cell.new(repository.movements_count.to_s, repository.movements_count.zero? ? nil : history_url(repository_id: repository.id),
            sort: BigDecimal.new(repository.movements_count)),
        ])
      end
      table = Table.new(I18n.t("stock.menu.stock_repositories"), columns, rows, reverse("stock:repositories"),
        empty_message: I18n.t("ui.stock.no_repositories"))
      actions = [] of Screen::Action
      if can?(SETTINGS_WRITE)
        actions << link_action("ui.stock.new_repository", reverse("stock:repository_new"), "primary", "plus")
        actions << link_action("ui.stock.settings", reverse("stock:settings"), icon: "settings")
        actions << link_action("ui.stock.rights.title", reverse("stock:rights"), icon: "lock")
      end
      list_page(I18n.t("stock.menu.stock_repositories"), table, stock_crumbs, "ui.stock.repositories_csv", actions,
        intro: I18n.t("ui.stock.repositories_intro"))
    end
  end

  class StockRepositoryNewHandler < RepositoryScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      show(repository_form(Stk::RepositoryInput.new("")))
    end

    def post
      input = read_repository
      result = Stk.create_repository(current.actor, input)
      if repository = result.value?
        flash["success"] = I18n.t("ui.stock.repository_created", name: repository.name)
        return go(repository_url(repository.id))
      end
      show(add_contract_errors(repository_form(input), result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.stock.new_repository"), crumbs, form, reverse("stock:repository_new"), I18n.t("ui.forms.create"),
        reverse("stock:repositories"))
    end
  end

  class StockRepositoryHandler < RepositoryScreen
    def get
      repository = Stk.repository(current.actor, id_param)
      actions = [link_action("ui.stock.history", history_url(repository_id: repository.id), icon: "clock")]
      if can?(SETTINGS_WRITE)
        actions << link_action("ui.forms.edit", reverse("stock:repository_edit", id: repository.id), "primary")
        actions << post_action("ui.forms.delete", reverse("stock:repository_delete", id: repository.id),
          "ui.stock.repository_delete_confirm", "danger")
      end
      items = [
        Screen::Item.new(I18n.t("ui.stock.repository_name"), repository.name),
        Screen::Item.new(I18n.t("ui.stock.address"), repository.address),
        Screen::Item.new(I18n.t("ui.stock.city"), repository.city),
        Screen::Item.new(I18n.t("ui.stock.country_code"), repository.country_code, mono: true),
        Screen::Item.new(I18n.t("ui.stock.phone"), repository.phone),
        Screen::Item.new(I18n.t("ui.stock.default_repository"), yes_no(repository.default)),
        Screen::Item.new(I18n.t("ui.stock.movements_count"), repository.movements_count.to_s, mono: true),
      ]
      detail_page(repository.name, crumbs, [Screen::Section.new(I18n.t("ui.stock.repository"), items)], actions)
    end
  end

  class StockRepositoryEditHandler < RepositoryScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      repository = Stk.repository(current.actor, id_param)
      show(repository, repository_form(to_input(repository)))
    end

    def post
      repository = Stk.repository(current.actor, id_param)
      input = read_repository
      result = Stk.update_repository(current.actor, repository.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.stock.repository_updated", name: updated.name)
        return go(repository_url(updated.id))
      end
      show(repository, add_contract_errors(repository_form(input), result.errors))
    end

    private def show(repository : Stk::RepositoryView, form : Form)
      form_page(I18n.t("ui.stock.edit_repository", name: repository.name), crumbs, form,
        reverse("stock:repository_edit", id: repository.id), I18n.t("ui.forms.save"), repository_url(repository.id))
    end
  end

  class StockRepositoryDeleteHandler < RepositoryScreen
    def post
      repository = Stk.repository(current.actor, id_param)
      result = Stk.delete_repository(current.actor, repository.id)
      if result.success?
        flash["success"] = I18n.t("ui.stock.repository_deleted", name: repository.name)
        go(reverse("stock:repositories"))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(repository_url(repository.id))
      end
    end
  end

  # Dépôt par défaut : celui où la Facturation et la Comptabilité inscrivent
  # leurs mouvements (vide : aucun mouvement automatique).
  class StockSettingsHandler < RepositoryScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      show(settings_form(Stk.settings(current.actor).default_repository_id.to_s))
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      result = Stk.update_settings(current.actor, Stk::SettingsInput.new(field("default_repository_id").to_i64?))
      if result.success?
        flash["success"] = I18n.t("ui.stock.settings_saved")
        return go(reverse("stock:repositories"))
      end
      show(add_contract_errors(settings_form(field("default_repository_id")), result.errors))
    end

    private def settings_form(selected : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("default_repository_id", I18n.t("ui.stock.default_repository"), "select", selected,
          options: repository_options(I18n.t("ui.stock.no_default_repository")), help: I18n.t("ui.stock.default_repository_help")),
      ])])
    end

    private def show(form : Form)
      form_page(I18n.t("ui.stock.settings"), crumbs, form, reverse("stock:settings"), I18n.t("ui.forms.save"),
        reverse("stock:repositories"))
    end
  end

  # Droits par dépôt, par profil (`profile_sec_repository` d'origine ;
  # DECISIONS D-R5-015) : choix du profil, puis aucun droit, lecture ou
  # écriture pour chaque dépôt. Un profil sans aucun droit n'est pas
  # restreint (droits globaux du Stock).
  class StockRightsHandler < RepositoryScreen
    ACCESSES = {"" => "ui.stock.rights.none", "R" => "ui.stock.rights.read", "W" => "ui.stock.rights.write"}

    def get
      require!(MODULE, SETTINGS_WRITE)
      show(query("profile").to_i64?)
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      profile_id = field("profile").to_i64? || raise Partiduo::Api::NotFound.new("profile", field("profile"))
      view = Stk.profile_rights(current.actor, profile_id)
      rights = view.rights.map do |right|
        Stk::RepositoryRightInput.new(right.repository_id, field("access_#{right.repository_id}"))
      end
      result = Stk.set_profile_rights(current.actor, profile_id, rights)
      if saved = result.value?
        flash["success"] = I18n.t(saved.restricted ? "ui.stock.rights.saved" : "ui.stock.rights.unrestricted")
        return go("#{reverse("stock:rights")}?#{URI::Params.encode({"profile" => profile_id.to_s})}")
      end
      show(profile_id, rights_form(view).add_errors(result.errors, fmt))
    end

    private def rights_form(view : Stk::ProfileRightsView) : Form
      options = ACCESSES.map { |value, key| option(value, I18n.t(key)) }
      fields = view.rights.map do |right|
        Form::Field.new("access_#{right.repository_id}", right.repository_name, "select", right.access,
          options: options)
      end
      fields << Form::Field.new("profile", "", "hidden", view.profile_id.to_s)
      Form.new([Form::Group.new(I18n.t("ui.stock.rights.repositories"), fields)])
    end

    private def show(profile_id : Int64?, form : Form? = nil)
      profiles = Stk.rights_profiles(current.actor)
      choices = [option("", I18n.t("ui.stock.rights.choose"))] + profiles.map do |profile|
        label = profile.restricted ? I18n.t("ui.stock.rights.restricted_profile", name: profile.name) : profile.name
        option(profile.id.to_s, label)
      end
      context["chooser"] = Form.new([Form::Group.new(nil, [
        Form::Field.new("profile", I18n.t("ui.stock.rights.profile"), "select", profile_id.to_s, options: choices),
      ])])
      context["chooser_title"] = I18n.t("ui.stock.rights.profile_step")
      context["chooser_action"] = reverse("stock:rights")
      if profile_id && profiles.any?(&.id.==(profile_id))
        form ||= rights_form(Stk.profile_rights(current.actor, profile_id))
      else
        form = nil
      end
      form_page(I18n.t("ui.stock.rights.title"), crumbs, form, reverse("stock:rights"), I18n.t("ui.forms.save"),
        reverse("stock:repositories"), intro: I18n.t("ui.stock.rights.intro"))
    end
  end

  # Articles suivis en stock (menu `stock:items`, attribut « code stock »
  # des fiches d'origine) : une fiche article et son code stock, commun à
  # plusieurs fiches au besoin ; quantité en stock tous dépôts confondus.
  abstract class StockItemScreen < StockScreen
    def crumbs : Array(Screen::Crumb)
      stock_crumbs("stock.menu.stock_items", reverse("stock:items"))
    end

    # Fiches articles actives pas encore suivies (et la fiche choisie).
    def card_options(selected : String) : Array(Form::Option)
      tracked = items.map(&.card_id).to_set
      query = Partiduo::Api::Cards::CardQuery.new(kind: "item", limit: 1_000)
      cards = Partiduo::Api::Cards.cards(current.actor, query).reject { |card| tracked.includes?(card.id) && card.id.to_s != selected }
      [option("", I18n.t("ui.stock.choose_card"))] + cards.map { |card| option(card.id.to_s, "#{card.code} · #{card.name}") }
    rescue Partiduo::Api::AccessDenied
      [option("", I18n.t("ui.stock.choose_card"))]
    end

    def stock_code_field(value : String) : Form::Field
      Form::Field.new("stock_code", I18n.t("ui.stock.stock_code"), value: value, mono: true, maxlength: 40,
        help: I18n.t("ui.stock.stock_code_help"))
    end
  end

  class StockItemsHandler < StockItemScreen
    def get
      quantities = Hash(String, BigDecimal).new(BigDecimal.new(0))
      Stk.valuation(current.actor, today).rows.each { |row| quantities[row.stock_code] += row.quantity }
      columns = [
        Table::Column.new("stock_code", I18n.t("ui.stock.stock_code"), "mono"),
        Table::Column.new("card", I18n.t("ui.stock.card"), "mono"),
        Table::Column.new("name", I18n.t("ui.stock.card_name")),
        Table::Column.new("quantity", I18n.t("ui.stock.quantity_today"), "amount"),
      ]
      editable = can?(SETTINGS_WRITE)
      rows = items.map do |item|
        Table::Row.new([
          Table::Cell.new(item.stock_code, history_url(item.stock_code)),
          Table::Cell.new(item.card_code, editable ? reverse("stock:item_edit", card_id: item.card_id) : card_url(item.card_id)),
          Table::Cell.new(item.card_name),
          quantity_cell(quantities[item.stock_code]),
        ])
      end
      table = Table.new(I18n.t("stock.menu.stock_items"), columns, rows, reverse("stock:items"),
        empty_message: I18n.t("ui.stock.no_items"))
      actions = [] of Screen::Action
      actions << link_action("ui.stock.track_item", reverse("stock:item_new"), "primary", "plus") if editable
      list_page(I18n.t("stock.menu.stock_items"), table, stock_crumbs, "ui.stock.items_csv", actions,
        intro: I18n.t("ui.stock.items_intro"))
    end
  end

  class StockItemNewHandler < StockItemScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      show(item_form("", ""))
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      card_id = field("card_id").to_i64?
      unless card_id
        form = item_form(field("card_id"), field("stock_code"))
        form.add_error("card_id", I18n.t("ui.forms.required"))
        return show(form)
      end
      result = Stk.track_item(current.actor, Stk::ItemInput.new(card_id, field("stock_code")))
      if item = result.value?
        flash["success"] = I18n.t("ui.stock.item_tracked", code: item.card_code, stock_code: item.stock_code)
        return go(reverse("stock:items"))
      end
      show(add_contract_errors(item_form(field("card_id"), field("stock_code")), result.errors))
    end

    private def item_form(card : String, code : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("card_id", I18n.t("ui.stock.card"), "select", card, options: card_options(card), required: true),
        stock_code_field(code),
      ])])
    end

    private def show(form : Form)
      form_page(I18n.t("ui.stock.track_item"), crumbs, form, reverse("stock:item_new"), I18n.t("ui.forms.create"),
        reverse("stock:items"), intro: I18n.t("ui.stock.track_intro"))
    end
  end

  class StockItemEditHandler < StockItemScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      item = find_item
      show(item, item_form(item.stock_code))
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      item = find_item
      result = Stk.track_item(current.actor, Stk::ItemInput.new(item.card_id, field("stock_code")))
      if updated = result.value?
        flash["success"] = I18n.t("ui.stock.item_tracked", code: updated.card_code, stock_code: updated.stock_code)
        return go(reverse("stock:items"))
      end
      show(item, add_contract_errors(item_form(field("stock_code")), result.errors))
    end

    private def find_item : Stk::ItemView
      Stk.item(current.actor, id_param("card_id")) || raise Partiduo::Api::NotFound.new("stock_item", id_param("card_id"))
    end

    private def item_form(code : String) : Form
      Form.new([Form::Group.new(nil, [stock_code_field(code)])])
    end

    private def show(item : Stk::ItemView, form : Form)
      actions = [
        link_action("ui.stock.card_sheet", card_url(item.card_id)),
        post_action("ui.stock.untrack_item", reverse("stock:item_delete", card_id: item.card_id), "ui.stock.untrack_confirm", "danger"),
      ]
      form_page(I18n.t("ui.stock.edit_item", code: item.card_code, name: item.card_name), crumbs, form,
        reverse("stock:item_edit", card_id: item.card_id), I18n.t("ui.forms.save"), reverse("stock:items"), actions)
    end
  end

  class StockItemDeleteHandler < StockItemScreen
    def post
      card_id = id_param("card_id")
      result = Stk.untrack_item(current.actor, card_id)
      if result.success?
        flash["success"] = I18n.t("ui.stock.item_untracked")
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(reverse("stock:items"))
    end
  end
end
