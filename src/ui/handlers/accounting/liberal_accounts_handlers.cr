# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Paramétrage comptable de la profession libérale (ADR-007 D6,
  # `Partiduo::Api::Accounting.liberal_accounts` et `set_liberal_account`) :
  # compte par nature (code), par rubrique de la 2035-A, par catégorie
  # d'immobilisation (`asset_<catégorie>`) et produit de cession
  # (`disposal`). Sans paramétrage, la Comptabilité prend le compte proposé
  # par le régime (D-LIB-003). Les natures ne sont proposées que si le
  # module liberal est actif et lisible.
  class LiberalAccountsHandler < ReferenceHandler
    alias Acc = Partiduo::Api::Accounting
    alias Liberal = Partiduo::Api::Liberal

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
      result = Acc.set_liberal_account(current.actor, key, field("account").presence)
      if result.success?
        flash["success"] = I18n.t("ui.liberal.accounts.saved", entry: label(key))
        return go(reverse("accounting:liberal_accounts"))
      end
      show(form.add_errors(result.errors, fmt), 422)
    end

    private def natures : Array(Liberal::NatureView)
      return [] of Liberal::NatureView unless module_active?(Liberal::MODULE_CODE)
      Liberal.natures(current.actor)
    rescue Partiduo::Api::AccessDenied
      [] of Liberal::NatureView
    end

    private def label(key : String) : String
      if Liberal::HEADINGS.includes?(key)
        I18n.t("liberal.headings.#{key}")
      elsif key.starts_with?("asset_") && Liberal::ASSET_CATEGORIES.includes?(key.lchop("asset_"))
        I18n.t("ui.liberal.accounts.asset", category: I18n.t("liberal.asset_categories.#{key.lchop("asset_")}"))
      elsif key == "disposal"
        I18n.t("ui.liberal.accounts.disposal")
      else
        natures.find(&.code.==(key)).try { |nature| I18n.t("ui.liberal.accounts.nature", label: nature.label) } || key
      end
    end

    private def keys : Array(String)
      Liberal::HEADINGS + Liberal::ASSET_CATEGORIES.map { |code| "asset_#{code}" } + ["disposal"] + natures.map(&.code)
    end

    private def build_form(key : String, account : String) : Form
      options = [option("", I18n.t("ui.liberal.accounts.choose"))] + keys.map { |value| option(value, "#{label(value)} (#{value})") }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("key", I18n.t("ui.liberal.accounts.key"), "select", key, required: true, options: options),
        Form::Field.new("account", I18n.t("ui.liberal.accounts.account"), value: account, mono: true, maxlength: 40,
          help: I18n.t("ui.liberal.accounts.account_help")),
      ])])
    end

    private def show(form : Form?, status : Int32 = 200) : Marten::HTTP::Response
      columns = [
        Table::Column.new("key", I18n.t("ui.liberal.accounts.key")),
        Table::Column.new("account", I18n.t("ui.liberal.accounts.account"), "mono"),
        Table::Column.new("label", I18n.t("ui.liberal.accounts.account_label"), secondary: true),
      ]
      rows = Acc.liberal_accounts(current.actor).map do |row|
        Table::Row.new([
          Table::Cell.new("#{label(row.key)} (#{row.key})", sort: row.key, csv: row.key),
          Table::Cell.new(row.account.number, reverse("accounting:account", id: row.account.id)),
          Table::Cell.new(row.account.label),
        ])
      end
      table = Table.new(I18n.t("ui.liberal.accounts.title"), columns, rows, reverse("accounting:liberal_accounts"),
        empty_message: I18n.t("ui.liberal.accounts.empty"))
      set_form(form, reverse("accounting:liberal_accounts"), I18n.t("ui.forms.save"), title: I18n.t("ui.liberal.accounts.set")) if form
      list_page(I18n.t("ui.liberal.accounts.title"), table,
        [crumb("core.menu.reference"), crumb("accounting.menu.acc_chart", reverse("accounting:chart"))],
        "ui.liberal.accounts.csv_name", intro: I18n.t("ui.liberal.accounts.intro"), status: status)
    end
  end
end
