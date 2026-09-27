# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Paramétrage comptable des registres de la micro-entreprise (ADR-007 D2,
  # `Partiduo::Api::Accounting.micro_accounts` et `set_micro_account`) :
  # compte de contrepartie par nature (code) ou par catégorie, TVA collectée
  # (`vat`) et déductible (`vat_deductible`). Sans paramétrage, la
  # Comptabilité prend le compte proposé par le régime (D-MIC-004). Les
  # natures ne sont proposées que si le module micro est actif et lisible.
  class MicroAccountsHandler < ReferenceHandler
    alias Acc = Partiduo::Api::Accounting

    CATEGORIES = %w[sale_bic service_bic bnc goods other vat vat_deductible]

    def get
      require!(Acc::MODULE_CODE, "accounting.account.read")
      show(can?("accounting.account.write") ? build_form("", "") : nil)
    end

    def post
      require!(Acc::MODULE_CODE, "accounting.account.write")
      key = field("key")
      form = build_form(key, field("account"))
      if key.empty?
        form.add_error("key", I18n.t("ui.forms.required"))
        return show(form, 422)
      end
      result = Acc.set_micro_account(current.actor, key, field("account").presence)
      if result.success?
        flash["success"] = I18n.t("ui.micro.accounts.saved", entry: label(key))
        return go(reverse("accounting:micro_accounts"))
      end
      show(form.add_errors(result.errors, fmt), 422)
    end

    private def natures : Array(Partiduo::Api::Micro::NatureView)
      return [] of Partiduo::Api::Micro::NatureView unless module_active?(Partiduo::Api::Micro::MODULE_CODE)
      Partiduo::Api::Micro.natures(current.actor)
    rescue Partiduo::Api::AccessDenied
      [] of Partiduo::Api::Micro::NatureView
    end

    private def label(key : String) : String
      if CATEGORIES.includes?(key)
        key.starts_with?("vat") ? I18n.t("ui.micro.accounts.keys.#{key}") : I18n.t("micro.categories.#{key}")
      else
        natures.find(&.code.==(key)).try { |nature| I18n.t("ui.micro.accounts.nature", label: nature.label) } || key
      end
    end

    private def keys : Array(String)
      CATEGORIES + natures.map(&.code)
    end

    private def build_form(key : String, account : String) : Form
      options = [option("", I18n.t("ui.micro.accounts.choose"))] + keys.map { |value| option(value, "#{label(value)} (#{value})") }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("key", I18n.t("ui.micro.accounts.key"), "select", key, required: true, options: options),
        Form::Field.new("account", I18n.t("ui.micro.accounts.account"), value: account, mono: true, maxlength: 40,
          help: I18n.t("ui.micro.accounts.account_help")),
      ])])
    end

    private def show(form : Form?, status : Int32 = 200) : Marten::HTTP::Response
      columns = [
        Table::Column.new("key", I18n.t("ui.micro.accounts.key")),
        Table::Column.new("account", I18n.t("ui.micro.accounts.account"), "mono"),
        Table::Column.new("label", I18n.t("ui.micro.accounts.account_label"), secondary: true),
      ]
      rows = Acc.micro_accounts(current.actor).map do |row|
        Table::Row.new([
          Table::Cell.new("#{label(row.key)} (#{row.key})", sort: row.key, csv: row.key),
          Table::Cell.new(row.account.number, reverse("accounting:account", id: row.account.id)),
          Table::Cell.new(row.account.label),
        ])
      end
      table = Table.new(I18n.t("ui.micro.accounts.title"), columns, rows, reverse("accounting:micro_accounts"),
        empty_message: I18n.t("ui.micro.accounts.empty"))
      set_form(form, reverse("accounting:micro_accounts"), I18n.t("ui.forms.save"), title: I18n.t("ui.micro.accounts.set")) if form
      list_page(I18n.t("ui.micro.accounts.title"), table,
        [crumb("core.menu.reference"), crumb("accounting.menu.acc_chart", reverse("accounting:chart"))],
        "ui.micro.accounts.csv_name", intro: I18n.t("ui.micro.accounts.intro"), status: status)
    end
  end
end
