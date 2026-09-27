# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Pièce à l'origine d'un mouvement de stock (`source` : `invoice:12`,
  # `entry:5`) : libellé et lien, seulement si le module qui la porte est
  # actif (ADR-006 D2).
  module StockSources
    SOURCES = %w[delivery_note invoice credit_note entry]

    def source_url(source : String) : String?
      kind, _, id_text = source.partition(':')
      id = id_text.to_i64? || return
      case kind
      when "delivery_note", "invoice", "credit_note"
        module_active?("INVOICING") ? reverse("invoicing:document", id: id) : nil
      when "entry"
        module_active?("ACCOUNTING") ? reverse("accounting:entry", id: id) : nil
      end
    end

    def source_label(source : String) : String
      kind, _, id_text = source.partition(':')
      return source if !SOURCES.includes?(kind) || id_text.empty?
      I18n.t("ui.stock.sources.#{kind}", id: id_text)
    end
  end

  # Base des écrans du module Stock (lot 6, `Partiduo::Api::Stock`) : dépôts,
  # dépôt par défaut, articles suivis, opérations manuelles, inventaire.
  # Module inactif : le contrat lève `ModuleDisabled`, l'écran répond 404
  # (D-UI-019). Les éditions (état, historique, valorisation) sont dans
  # `report_handlers.cr`.
  abstract class StockScreen < ReferenceHandler
    include StockSources

    alias Stk = Partiduo::Api::Stock

    MODULE         = "STOCK"
    READ           = "stock.movement.read"
    WRITE          = "stock.movement.write"
    SETTINGS_WRITE = "stock.settings.write"

    # Lignes vides proposées après les lignes remplies.
    SPARE_ROWS = 3

    @repositories : Array(Stk::RepositoryView)?
    @items : Array(Stk::ItemView)?

    def stock_crumbs(label_key : String? = nil, url : String? = nil, parent : String = "core.menu.reference") : Array(Screen::Crumb)
      crumbs = [crumb(parent)]
      crumbs << crumb(label_key, url) if label_key
      crumbs
    end

    def repositories : Array(Stk::RepositoryView)
      @repositories ||= Stk.repositories(current.actor)
    end

    def items : Array(Stk::ItemView)
      @items ||= Stk.items(current.actor).sort_by { |item| {item.stock_code, item.card_code} }
    end

    def item_label(item : Stk::ItemView) : String
      item.stock_code == item.card_code ? "#{item.card_code} · #{item.card_name}" : "#{item.card_code} · #{item.card_name} (#{item.stock_code})"
    end

    # Choix d'un dépôt ; `blank` : libellé de l'option vide (aucune si nil).
    def repository_options(blank : String? = nil) : Array(Form::Option)
      options = repositories.map { |repository| option(repository.id.to_s, repository.name) }
      blank ? [option("", blank)] + options : options
    end

    def item_options : Array(Form::Option)
      [option("", I18n.t("ui.stock.choose_item"))] + items.map { |item| option(item.card_id.to_s, item_label(item)) }
    end

    # Dépôt proposé : le dépôt par défaut, sinon le premier.
    def default_repository_id : Int64?
      Stk.settings(current.actor).default_repository_id || repositories.first?.try(&.id)
    end

    # Quantité affichée (jusqu'à quatre décimales, sans zéros inutiles).
    def quantity(value : BigDecimal) : String
      fmt.number(value)
    end

    def quantity_cell(value : BigDecimal, url : String? = nil) : Table::Cell
      Table::Cell.new(quantity(value), url, sort: value, csv: fmt.number(value, group: false))
    end

    def input_quantity(value : BigDecimal?) : String
      fmt.input_number(value, 4)
    end

    # Chemin d'erreur du contrat → champ du formulaire : `lines[2].quantity`
    # → `lines-2-quantity`.
    def error_field(path : String) : String
      path.gsub(/\[(\d+)\]\.?/) { "-#{$1}-" }.rchop('-')
    end

    def add_contract_errors(form : Form, errors : Array(Partiduo::Api::FieldError)) : Form
      errors.each { |error| form.add_error(error_field(error.field), fmt.message(error)) }
      form
    end

    # Indices des lignes envoyées (`lines-3-quantity` → 3), dans l'ordre.
    def row_indices(prefix : String) : Array(Int32)
      pattern = /\A#{Regex.escape(prefix)}-(\d+)-/
      request.data.compact_map { |(name, _)| name.match(pattern).try(&.[1].to_i) }.uniq!.sort!
    end

    def repository_url(id : Int64) : String
      reverse("stock:repository", id: id)
    end

    def change_url(id : Int64) : String
      reverse("stock:change", id: id)
    end

    def card_url(id : Int64) : String
      reverse("cards:show", id: id)
    end

    # Historique d'un code stock (ou d'un dépôt).
    def history_url(stock_code : String? = nil, repository_id : Int64? = nil) : String
      params = {} of String => String
      stock_code.try { |code| params["stock_code"] = code }
      repository_id.try { |id| params["repository"] = id.to_s }
      params["f"] = "1"
      "#{reverse("stock:history")}?#{URI::Params.encode(params)}"
    end

    def direction_label(direction : String) : String
      I18n.t(direction == "in" ? "ui.stock.direction_in" : "ui.stock.direction_out")
    end

    def kind_label(kind : String) : String
      I18n.t(kind == "inventory" ? "ui.stock.kind_inventory" : "ui.stock.kind_change")
    end

    def iso(day : Time?) : String?
      day.try(&.to_s("%Y-%m-%d"))
    end

    def today : Time
      Partiduo::Api::Core.today
    end

    def parse_day(text : String) : Time?
      fmt.parse_short_date(text, today)
    end
  end
end
