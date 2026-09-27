# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Livre des recettes et registre des achats (ADR-007 D1, D3) : liste de
  # l'année et total, éditions CSV et PDF du contrat, saisie en quelques
  # champs pensée d'abord pour le téléphone (montant, date, nature, mode de
  # règlement, client ou fournisseur, photo du justificatif), consultation
  # d'une ligne et annulation par contre-passation datée du jour (une ligne
  # inscrite ne se modifie jamais, D-MIC-003).
  #
  # `register` : `receipt` (recettes) ou `purchase` (achats) ; les routes
  # `micro:receipts…` et `micro:purchases…` ont chacune leurs handlers.
  abstract class RegisterScreen < MicroScreen
    abstract def register : String

    def receipt? : Bool
      register == "receipt"
    end

    # Nom de la famille de routes : `receipts` ou `purchases`.
    def route_base : String
      receipt? ? "receipts" : "purchases"
    end

    def list_url : String
      reverse("micro:#{route_base}")
    end

    def line_url(id : Int64) : String
      reverse("micro:#{route_base.rchop('s')}", id: id)
    end

    def new_url : String
      reverse("micro:#{route_base.rchop('s')}_new")
    end

    # Clé i18n propre au registre (`ui.micro.receipt.title`).
    def t(key : String, params = {} of String => String) : String
      I18n.t("ui.micro.#{register}.#{key}", params)
    end

    def register_crumbs : Array(Screen::Crumb)
      micro_crumbs << Screen::Crumb.new(t("title"), list_url)
    end

    def lines(query : Micro::RegisterQuery) : Array(Micro::LineView)
      receipt? ? Micro.receipts(current.actor, query) : Micro.purchases(current.actor, query)
    end

    def line(id : Int64) : Micro::LineView
      receipt? ? Micro.receipt(current.actor, id) : Micro.purchase(current.actor, id)
    end

    def year_query(year : Int32) : Micro::RegisterQuery
      Micro::RegisterQuery.new(from: Time.utc(year, 1, 1), to: Time.utc(year, 12, 31), limit: Micro::MAX_LIMIT)
    end

    # Totaux de la requête, par agrégat (sans charger les lignes).
    def totals(query : Micro::RegisterQuery) : Micro::TotalsView
      receipt? ? Micro.receipts_total(current.actor, query) : Micro.purchases_total(current.actor, query)
    end

    # Récapitulatif annuel par nature.
    def nature_totals(year : Int32) : Array(Micro::NatureTotalView)
      receipt? ? Micro.receipt_totals(current.actor, year) : Micro.purchase_totals(current.actor, year)
    end

    def method_label(method : String) : String
      I18n.t("micro.methods.#{method}")
    end

    # Client ou fournisseur d'une ligne : nom saisi, sinon nom de la fiche.
    def party(line : Micro::LineView) : String
      return line.party_name unless line.party_name.empty?
      line.card_id.try { |id| Partiduo::Api::Cards.card(current.actor, id).name } || ""
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      ""
    end
  end

  module ReceiptRegister
    def register : String
      "receipt"
    end
  end

  module PurchaseRegister
    def register : String
      "purchase"
    end
  end

  # Liste de l'année (onglets d'années ; au plus `MAX_LIMIT` lignes, les
  # plus récentes), total encaissé ou dépensé et récapitulatif par nature
  # (agrégats du contrat), éditions `?format=csv|pdf` du contrat (colonnes
  # réglementaires).
  abstract class RegisterListHandler < RegisterScreen
    def get
      year = year_param
      query = year_query(year)
      if query("format").in?("csv", "pdf")
        return export(query, query("format") == "pdf" ? Micro::ExportFormat::Pdf : Micro::ExportFormat::Csv)
      end
      summary = totals(query)
      offset = Math.max(summary.count - Micro::MAX_LIMIT, 0)
      rows = lines(query.copy_with(offset: offset)).reverse!
      footers = [footer(t("total"), summary.amount, "pd-class")]
      footers << footer(I18n.t("ui.micro.fields.vat_amount"), summary.vat_amount) unless summary.vat_amount.zero?
      nature_totals(year).each do |item|
        footers << footer(I18n.t("ui.micro.recap.nature", nature: item.nature_label), item.amount)
      end
      table = Table.new(t("title"), columns, rows.map { |item| row(item) }, list_url, {"year" => year.to_s},
        empty_message: t("empty"), footer_rows: footers)
      table.pdf = true
      actions = [] of Screen::Action
      actions << link_action("ui.micro.#{register}.new", new_url, "primary", "plus") if can?(WRITE)
      list_page("#{t("title")} #{year}", table, micro_crumbs, "ui.micro.#{register}.csv_name", actions,
        tabs: year_tabs(list_url, year), tabs_label: I18n.t("ui.micro.year"), intro: t("intro"))
    end

    private def export(query : Micro::RegisterQuery, format : Micro::ExportFormat) : Marten::HTTP::Response
      file = receipt? ? Micro.export_receipts(current.actor, query, format) : Micro.export_purchases(current.actor, query, format)
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end

    private def columns : Array(Table::Column)
      [
        Table::Column.new("date", I18n.t("ui.micro.columns.date"), "mono"),
        Table::Column.new("number", I18n.t("ui.micro.columns.number"), "mono", secondary: true),
        Table::Column.new("party", t("party")),
        Table::Column.new("nature", I18n.t("ui.micro.columns.nature"), secondary: true),
        Table::Column.new("method", I18n.t("ui.micro.columns.method"), secondary: true),
        Table::Column.new("amount", t("amount"), "amount"),
      ]
    end

    private def row(item : Micro::LineView) : Table::Row
      state = if item.reversal?
                I18n.t("ui.micro.line.reversal")
              elsif item.reversed_by_id
                I18n.t("ui.micro.line.cancelled")
              end
      Table::Row.new([
        Table::Cell.new(fmt.date(item.date), line_url(item.id), sort: date_key(item.date), csv: date_key(item.date)),
        Table::Cell.new(item.number),
        Table::Cell.new(party(item).presence || item.label, tag: state),
        Table::Cell.new(item.nature_label),
        Table::Cell.new(method_label(item.method)),
        Table::Cell.new(euros(item.amount), sort: item.amount, csv: fmt.csv_amount(item.amount)),
      ], item.reversed_by_id || item.reversal? ? "pd-row-closed" : "")
    end

    private def footer(label : String, total : BigDecimal, css : String = "") : Table::Row
      Table::Row.new([
        Table::Cell.new(label), Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(""), Table::Cell.new(""),
        Table::Cell.new(euros(total), sort: total, csv: fmt.csv_amount(total)),
      ], css)
    end
  end

  class ReceiptsHandler < RegisterListHandler
    include ReceiptRegister
  end

  class PurchasesHandler < RegisterListHandler
    include PurchaseRegister
  end

  # Saisie d'une recette ou d'un achat, en quelques champs : montant, date
  # (du jour par défaut), nature, mode de règlement, client ou fournisseur ;
  # le reste (désignation, pièce, TVA comprise, photo du justificatif) sous
  # « Plus de détails », sauf la photo, visible d'emblée sur téléphone.
  abstract class RegisterNewHandler < RegisterScreen
    FIELDS = %w[amount date nature_id method party_name label reference vat_amount attachment_id]

    def get
      require!(MODULE, WRITE)
      values = {"date" => today.to_s("%Y-%m-%d"), "method" => receipt? ? "transfer" : "card"}
      show(build_form(values))
    end

    def post
      require!(MODULE, WRITE)
      values = FIELDS.to_h { |name| {name, field(name)} }
      form = build_form(values)
      upload(form, values)
      input = read(form, values)
      return show(build_form(values).tap { |shown| copy_errors(form, shown) }, 422) if input.nil?
      result = receipt? ? Micro.record_receipt(current.actor, input.as(Micro::ReceiptInput)) : Micro.record_purchase(current.actor, input.as(Micro::PurchaseInput))
      if created = result.value?
        flash["success"] = t("recorded", {"number" => created.number, "amount" => euros(created.amount)})
        return go(field("again") == "1" ? new_url : list_url)
      end
      shown = build_form(values)
      shown.add_errors(result.errors, fmt)
      show(shown, 422)
    end

    private def copy_errors(from : Form, to : Form) : Nil
      from.fields.each { |item| item.errors.try &.each { |message| to.add_error(item.name, message) } }
      from.base_errors.try &.each { |message| to.add_error(Partiduo::Api::FieldError::BASE, message) }
    end

    # Photo ou PDF du justificatif, déposé au socle avant l'inscription ;
    # gardé (`attachment_id`) si la saisie est refusée.
    private def upload(form : Form, values : Hash(String, String)) : Nil
      return unless values["attachment_id"].empty?
      file = request.data["attachment_file"]?
      return unless file.is_a?(Marten::HTTP::UploadedFile) && file.size > 0
      result = ReceivedInvoiceUpload.store(current.actor, file)
      if view = result.value?
        values["attachment_id"] = view.id.to_s
      else
        form.add_errors(result.errors, fmt)
      end
    end

    private def read(form : Form, values : Hash(String, String)) : (Micro::ReceiptInput | Micro::PurchaseInput)?
      amount = fmt.parse_decimal(values["amount"])
      form.add_error("amount", I18n.t(values["amount"].empty? ? "ui.forms.required" : "ui.forms.invalid_number")) unless amount
      date = fmt.parse_date(values["date"])
      form.add_error("date", I18n.t("ui.forms.invalid_date")) unless date
      nature_id = values["nature_id"].to_i64?
      form.add_error("nature_id", I18n.t("ui.forms.required")) unless nature_id
      vat = BigDecimal.new(0)
      unless values["vat_amount"].empty?
        vat = fmt.parse_decimal(values["vat_amount"]) || begin
          form.add_error("vat_amount", I18n.t("ui.forms.invalid_number"))
          BigDecimal.new(0)
        end
      end
      return if form.invalid || amount.nil? || date.nil? || nature_id.nil?
      attachment_id = values["attachment_id"].to_i64?
      if receipt?
        Micro::ReceiptInput.new(date: date, nature_id: nature_id, amount: amount, method: values["method"],
          party_name: values["party_name"], label: values["label"], reference: values["reference"],
          attachment_id: attachment_id, vat_amount: vat)
      else
        Micro::PurchaseInput.new(date: date, nature_id: nature_id, amount: amount, method: values["method"],
          party_name: values["party_name"], label: values["label"], reference: values["reference"],
          attachment_id: attachment_id, vat_amount: vat)
      end
    end

    # TVA comprise (collectée ou déductible) : seulement une fois la
    # franchise en base quittée.
    private def vat_liable? : Bool
      !Micro.settings(current.actor).vat_liable_since.nil?
    end

    private def build_form(values : Hash(String, String)) : Form
      Form.new([Form::Group.new(nil, main_fields(values)), Form::Group.new(I18n.t("ui.micro.fields.more"), more_fields(values))])
    end

    # Nature proposée : celle saisie, sinon (recette) celle des paramètres,
    # sinon la première.
    private def nature_value(values : Hash(String, String), natures : Array(Micro::NatureView)) : String
      chosen = values["nature_id"]?.presence
      chosen ||= Micro.settings(current.actor).default_nature_id.try(&.to_s) if receipt?
      chosen || natures.first?.try(&.id.to_s) || ""
    end

    private def main_fields(values : Hash(String, String)) : Array(Form::Field)
      natures = Micro.natures(current.actor, register, enabled_only: true)
      methods = Micro::METHODS.map { |code| option(code, I18n.t("micro.methods.#{code}")) }
      [
        Form::Field.new("amount", t("amount_field"), "number", values["amount"]? || "", required: true, mono: true,
          placeholder: "0,00", help: t("amount_help")),
        Form::Field.new("date", t("date_field"), "date", values["date"]? || "", required: true),
        Form::Field.new("nature_id", I18n.t("ui.micro.columns.nature"), "select", nature_value(values, natures), required: true,
          options: natures.map { |item| option(item.id.to_s, item.label) }),
        Form::Field.new("method", I18n.t("ui.micro.columns.method"), "select", values["method"]? || "", required: true, options: methods),
        Form::Field.new("party_name", t("party"), value: values["party_name"]? || "", maxlength: 100),
      ]
    end

    private def more_fields(values : Hash(String, String)) : Array(Form::Field)
      more = [
        Form::Field.new("label", I18n.t("ui.micro.fields.label"), value: values["label"]? || "", maxlength: 100,
          help: t("label_help")),
        Form::Field.new("reference", I18n.t("ui.micro.fields.reference"), value: values["reference"]? || "", maxlength: 100,
          help: I18n.t("ui.micro.fields.reference_help")),
      ]
      # Recette : TVA collectée ; achat : TVA déductible (D-MIC-013).
      if vat_liable? || !values["vat_amount"]?.to_s.empty?
        more << Form::Field.new("vat_amount", I18n.t("ui.micro.fields.vat_amount"), "number", values["vat_amount"]? || "", mono: true,
          help: t("vat_help"))
      end
      more << Form::Field.new("attachment_id", "", "hidden", values["attachment_id"]? || "")
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      context["title"] = t("new")
      context["crumbs"] = register_crumbs
      context["form"] = form
      context["main"] = form.groups[0].fields
      context["more"] = form.groups[1].fields
      context["more_open"] = form.groups[1].fields.any?(&.errors)
      context["attachment_kept"] = form.fields.find(&.name.==("attachment_id")).try(&.value.presence)
      context["form_action"] = new_url
      context["cancel_url"] = list_url
      page("ui/micro/entry.html", status: status)
    end
  end

  class ReceiptNewHandler < RegisterNewHandler
    include ReceiptRegister
  end

  class PurchaseNewHandler < RegisterNewHandler
    include PurchaseRegister
  end

  # Consultation d'une ligne ; annulation (contre-passation datée du jour)
  # tant qu'elle n'est ni annulée ni elle-même une annulation.
  abstract class RegisterLineHandler < RegisterScreen
    def get
      item = line(id_param)
      details = [
        Screen::Item.new(I18n.t("ui.micro.columns.number"), item.number, mono: true),
        Screen::Item.new(t("date_field"), fmt.date(item.date)),
        Screen::Item.new(t("amount"), euros(item.amount)),
        Screen::Item.new(I18n.t("ui.micro.fields.vat_amount"), item.vat_amount.zero? ? "" : euros(item.vat_amount)),
        Screen::Item.new(t("party"), party(item)),
        Screen::Item.new(I18n.t("ui.micro.columns.nature"), "#{item.nature_label} · #{category_label(item.category)}"),
        Screen::Item.new(I18n.t("ui.micro.columns.method"), method_label(item.method)),
        Screen::Item.new(I18n.t("ui.micro.fields.label"), item.label),
        Screen::Item.new(I18n.t("ui.micro.fields.reference"), item.reference),
        Screen::Item.new(I18n.t("ui.micro.fields.origin"), I18n.t("ui.micro.origins.#{item.origin}")),
      ]
      if attachment = item.attachment_id
        details << Screen::Item.new(I18n.t("ui.micro.fields.attachment"), I18n.t("ui.micro.fields.attachment_open"),
          reverse("core:attachment", id: attachment))
      end
      item.reversal_of_id.try { |id| details << Screen::Item.new(I18n.t("ui.micro.line.cancels"), line(id).number, line_url(id), mono: true) }
      item.reversed_by_id.try { |id| details << Screen::Item.new(I18n.t("ui.micro.line.cancelled_by"), line(id).number, line_url(id), mono: true) }
      actions = [] of Screen::Action
      if can?(WRITE) && !item.reversal? && item.reversed_by_id.nil?
        actions << post_action("ui.micro.line.cancel", reverse("micro:#{route_base.rchop('s')}_reverse", id: item.id),
          "ui.micro.line.cancel_confirm", "danger", "x")
      end
      status = item.reversal? ? I18n.t("ui.micro.line.reversal") : (item.reversed_by_id ? I18n.t("ui.micro.line.cancelled") : nil)
      intro = item.locked ? I18n.t("ui.micro.line.locked") : I18n.t("ui.micro.line.intangible")
      detail_page("#{t("one")} #{item.number}", register_crumbs, [Screen::Section.new(t("one"), details)], actions,
        status_tag: status, intro: intro)
    end
  end

  class ReceiptHandler < RegisterLineHandler
    include ReceiptRegister
  end

  class PurchaseHandler < RegisterLineHandler
    include PurchaseRegister
  end

  # Annulation d'une ligne : contre-passation datée du jour (le contrat
  # refuse une ligne déjà annulée ou une annulation).
  abstract class RegisterReverseHandler < RegisterScreen
    def post
      require!(MODULE, WRITE)
      item = line(id_param)
      input = Micro::ReverseInput.new(item.id, today)
      result = receipt? ? Micro.reverse_receipt(current.actor, input) : Micro.reverse_purchase(current.actor, input)
      if reversal = result.value?
        flash["success"] = I18n.t("ui.micro.line.cancelled_flash", number: item.number, reversal: reversal.number)
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(line_url(item.id))
    end
  end

  class ReceiptReverseHandler < RegisterReverseHandler
    include ReceiptRegister
  end

  class PurchaseReverseHandler < RegisterReverseHandler
    include PurchaseRegister
  end
end
