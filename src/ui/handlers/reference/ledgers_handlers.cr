# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Journaux du module Comptabilité (`Partiduo::Api::Accounting`,
  # successeur de `jrn_def`) : liste des journaux visibles, création,
  # consultation, modification, suppression. Module inactif : 404.
  abstract class LedgerScreen < ReferenceHandler
    KINDS = Partiduo::Api::Accounting::LedgerKind.values

    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.reference"), crumb("accounting.menu.acc_ledgers", reverse("accounting:ledgers"))]
    end

    def kind_label(kind : Partiduo::Api::Accounting::LedgerKind) : String
      I18n.t("accounting.ledger_kinds.#{kind.code}")
    end

    def access_label(access : Partiduo::Api::Accounting::LedgerAccess) : String
      I18n.t("accounting.ledger_access.#{access.to_s.downcase}")
    end

    def kind_options : Array(Form::Option)
      KINDS.map { |kind| option(kind.code, kind_label(kind)) }
    end

    def ledger_form(input : Partiduo::Api::Accounting::LedgerInput? = nil, next_receipt : String = "") : Form
      values = input || Partiduo::Api::Accounting::LedgerInput.new(name: "", kind: Partiduo::Api::Accounting::LedgerKind::Purchase)
      currencies = [option("", I18n.t("ui.ledgers.currency_default"))] +
                   Partiduo::Api::Core.currencies(current.actor).map { |currency| option(currency.code, "#{currency.code} — #{currency.name}") }
      Form.new([
        Form::Group.new(nil, [
          Form::Field.new("name", I18n.t("ui.ledgers.name"), value: values.name, required: true, maxlength: 80, wide: true),
          Form::Field.new("kind", I18n.t("ui.ledgers.kind"), "select", values.kind.code, options: kind_options, required: true),
          Form::Field.new("code", I18n.t("ui.ledgers.code"), value: values.code || "", mono: true, maxlength: 10,
            help: I18n.t("ui.ledgers.code_help")),
          Form::Field.new("default_account", I18n.t("ui.ledgers.default_account"), value: values.default_account || "",
            mono: true, help: I18n.t("ui.ledgers.default_account_help")),
          Form::Field.new("bank_card", I18n.t("ui.ledgers.bank_card"), value: values.bank_card || "", mono: true,
            help: I18n.t("ui.ledgers.bank_card_help")),
          Form::Field.new("currency_code", I18n.t("ui.ledgers.currency"), "select", values.currency_code || "", options: currencies),
          Form::Field.new("description", I18n.t("ui.ledgers.description"), "textarea", values.description, wide: true),
          Form::Field.new("enabled", I18n.t("ui.forms.enabled"), "checkbox", values.enabled ? "1" : ""),
        ]),
        Form::Group.new(I18n.t("ui.ledgers.receipts"), [
          Form::Field.new("receipt_prefix", I18n.t("ui.ledgers.receipt_prefix"), value: values.receipt_prefix, mono: true),
          Form::Field.new("receipt_padding", I18n.t("ui.ledgers.receipt_padding"), value: values.receipt_padding.to_s, mono: true),
          Form::Field.new("next_receipt_number", I18n.t("ui.ledgers.next_receipt_number"),
            value: values.next_receipt_number.try(&.to_s) || "", mono: true,
            help: next_receipt.empty? ? I18n.t("ui.ledgers.next_receipt_help") : I18n.t("ui.ledgers.next_receipt_current", receipt: next_receipt)),
        ]),
      ])
    end

    def read_input(form_errors : Array({String, String})) : Partiduo::Api::Accounting::LedgerInput
      kind = KINDS.find { |item| item.code == field("kind") } || Partiduo::Api::Accounting::LedgerKind::Purchase
      padding = integer("receipt_padding", form_errors, required: false) || 0
      next_number = field("next_receipt_number").presence.try do |text|
        text.to_i64? || (form_errors << {"next_receipt_number", I18n.t("ui.forms.invalid_integer")}; nil)
      end
      Partiduo::Api::Accounting::LedgerInput.new(
        name: field("name"), kind: kind, code: field("code").presence, description: field("description", strip: false).strip,
        enabled: checkbox("enabled"), default_account: field("default_account").presence,
        receipt_prefix: field("receipt_prefix"), receipt_padding: padding, next_receipt_number: next_number,
        currency_code: field("currency_code").presence, bank_card: field("bank_card").presence,
      )
    end

    def refused(input, form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = ledger_form(input)
      {"receipt_padding", "next_receipt_number"}.each do |name|
        form.fields.find(&.name.==(name)).try(&.value=(field(name)))
      end
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end
  end

  class LedgersHandler < LedgerScreen
    def get
      kind = KINDS.find { |item| item.code == query("kind") }
      ledgers = Partiduo::Api::Accounting.ledgers(current.actor, kind)
      columns = [
        Table::Column.new("code", I18n.t("ui.ledgers.code"), "mono"),
        Table::Column.new("name", I18n.t("ui.ledgers.name")),
        Table::Column.new("kind", I18n.t("ui.ledgers.kind")),
        Table::Column.new("default_account", I18n.t("ui.ledgers.default_account"), "mono", secondary: true),
        Table::Column.new("next_receipt", I18n.t("ui.ledgers.next_receipt"), "mono", secondary: true),
        Table::Column.new("currency", I18n.t("ui.ledgers.currency"), "mono", secondary: true),
        Table::Column.new("access", I18n.t("ui.ledgers.access"), secondary: true),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status")),
      ]
      rows = ledgers.map do |ledger|
        Table::Row.new([
          Table::Cell.new(ledger.code, reverse("accounting:ledger", id: ledger.id)),
          Table::Cell.new(ledger.name),
          Table::Cell.new(kind_label(ledger.kind)),
          Table::Cell.new(ledger.default_account.try(&.number) || ""),
          Table::Cell.new(ledger.next_receipt),
          Table::Cell.new(ledger.currency_code),
          Table::Cell.new(access_label(ledger.access)),
          Table::Cell.new(I18n.t(ledger.enabled ? "ui.forms.active" : "ui.forms.inactive")),
        ], ledger.enabled ? "" : "pd-row-closed")
      end
      params = kind ? {"kind" => kind.code} : {} of String => String
      table = Table.new(I18n.t("accounting.menu.acc_ledgers"), columns, rows, reverse("accounting:ledgers"), params,
        empty_message: I18n.t("ui.ledgers.empty"))
      actions = [] of Screen::Action
      actions << link_action("ui.ledgers.new", reverse("accounting:ledger_new"), "primary", "plus") if can?("accounting.ledger.write")
      kinds = [option("", I18n.t("ui.ledgers.all_kinds"))] + kind_options
      filters = search_filters([Form::Field.new("kind", I18n.t("ui.ledgers.kind"), "select", query("kind"), options: kinds)])
      list_page(I18n.t("accounting.menu.acc_ledgers"), table, crumbs[0, 1], "ui.ledgers.csv_name", actions, filters: filters)
    end
  end

  class LedgerNewHandler < LedgerScreen
    def get
      require!("ACCOUNTING", "accounting.ledger.write")
      show(ledger_form)
    end

    def post
      form_errors = [] of {String, String}
      input = read_input(form_errors)
      return show(refused(input, form_errors)) unless form_errors.empty?
      result = Partiduo::Api::Accounting.create_ledger(current.actor, input)
      if ledger = result.value?
        flash["success"] = I18n.t("ui.ledgers.created", name: ledger.name)
        return go(reverse("accounting:ledger", id: ledger.id))
      end
      show(refused(input, form_errors, result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.ledgers.new"), crumbs, form, reverse("accounting:ledger_new"), I18n.t("ui.forms.create"),
        reverse("accounting:ledgers"))
    end
  end

  class LedgerHandler < LedgerScreen
    def get
      ledger = Partiduo::Api::Accounting.ledger(current.actor, id_param)
      account = ledger.default_account
      items = [
        Screen::Item.new(I18n.t("ui.ledgers.code"), ledger.code, mono: true),
        Screen::Item.new(I18n.t("ui.ledgers.name"), ledger.name),
        Screen::Item.new(I18n.t("ui.ledgers.kind"), kind_label(ledger.kind)),
        Screen::Item.new(I18n.t("ui.ledgers.default_account"), account ? "#{account.number} — #{account.label}" : "",
          account.try { |item| reverse("accounting:account", id: item.id) }),
        Screen::Item.new(I18n.t("ui.ledgers.bank_card"), ledger.bank_card_code || "",
          ledger.bank_card_id.try { |id| reverse("cards:show", id: id) }),
        Screen::Item.new(I18n.t("ui.ledgers.currency"), ledger.currency_code, mono: true),
        Screen::Item.new(I18n.t("ui.ledgers.description"), ledger.description),
        Screen::Item.new(I18n.t("ui.ledgers.access"), access_label(ledger.access)),
      ]
      receipts = [
        Screen::Item.new(I18n.t("ui.ledgers.receipt_prefix"), ledger.receipt_prefix, mono: true),
        Screen::Item.new(I18n.t("ui.ledgers.receipt_padding"), ledger.receipt_padding.to_s, mono: true),
        Screen::Item.new(I18n.t("ui.ledgers.last_receipt"), ledger.last_receipt_number.to_s, mono: true),
        Screen::Item.new(I18n.t("ui.ledgers.next_receipt"), ledger.next_receipt, mono: true),
      ]
      actions = [] of Screen::Action
      if can?("accounting.ledger.write")
        actions << link_action("ui.forms.edit", reverse("accounting:ledger_edit", id: ledger.id), "primary")
        actions << post_action("ui.forms.delete", reverse("accounting:ledger_delete", id: ledger.id), "ui.ledgers.delete_confirm", "danger")
      end
      detail_page(I18n.t("ui.ledgers.title", code: ledger.code, name: ledger.name), crumbs,
        [Screen::Section.new(I18n.t("ui.ledgers.summary"), items), Screen::Section.new(I18n.t("ui.ledgers.receipts"), receipts)],
        actions, status_tag: ledger.enabled ? nil : I18n.t("ui.forms.inactive"))
    end
  end

  class LedgerEditHandler < LedgerScreen
    def get
      require!("ACCOUNTING", "accounting.ledger.write")
      ledger = Partiduo::Api::Accounting.ledger(current.actor, id_param)
      input = Partiduo::Api::Accounting::LedgerInput.new(
        name: ledger.name, kind: ledger.kind, code: ledger.code, description: ledger.description, enabled: ledger.enabled,
        default_account: ledger.kind.financial? ? nil : ledger.default_account.try(&.number),
        receipt_prefix: ledger.receipt_prefix,
        receipt_padding: ledger.receipt_padding, currency_code: ledger.currency_code, bank_card: ledger.bank_card_code,
      )
      show(ledger_form(input, ledger.next_receipt), ledger)
    end

    def post
      ledger = Partiduo::Api::Accounting.ledger(current.actor, id_param)
      form_errors = [] of {String, String}
      input = read_input(form_errors)
      return show(refused(input, form_errors), ledger) unless form_errors.empty?
      result = Partiduo::Api::Accounting.update_ledger(current.actor, ledger.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.ledgers.updated", name: updated.name)
        return go(reverse("accounting:ledger", id: updated.id))
      end
      show(refused(input, form_errors, result.errors), ledger)
    end

    private def show(form : Form, ledger : Partiduo::Api::Accounting::LedgerView)
      form_page(I18n.t("ui.ledgers.edit", code: ledger.code), crumbs, form, reverse("accounting:ledger_edit", id: ledger.id),
        I18n.t("ui.forms.save"), reverse("accounting:ledger", id: ledger.id))
    end
  end

  class LedgerDeleteHandler < LedgerScreen
    def post
      ledger = Partiduo::Api::Accounting.ledger(current.actor, id_param)
      if flash_result(Partiduo::Api::Accounting.delete_ledger(current.actor, ledger.id), "ui.ledgers.deleted", {"name" => ledger.name})
        go(reverse("accounting:ledgers"))
      else
        go(reverse("accounting:ledger", id: ledger.id))
      end
    end
  end
end
