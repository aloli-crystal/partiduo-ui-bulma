# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Facturation allégée du mode simplifié (ADR-007 D3) : les commandes du
  # module Facturation (`Api::Invoicing.create_document`, puis validation,
  # envoi et règlement sur l'écran de la facture), présentées avec moins de
  # champs : client (existant ou nouveau, par son nom), trois lignes
  # (désignation, quantité, prix), échéance. Numérotation, intangibilité et
  # mentions obligatoires restent celles du module (ADR-006 D5).
  #
  # En franchise en base (aucune bascule vers la TVA notée par le module
  # micro), chaque ligne prend le taux d'exonération `VATEX-FR-FRANCHISE` :
  # la mention « TVA non applicable, art. 293 B du CGI » est apposée par la
  # Facturation. Après la bascule, un taux est choisi pour la facture.
  class MicroInvoiceNewHandler < InvoicingScreen
    FRANCHISE  = "VATEX-FR-FRANCHISE"
    LINE_COUNT = 3

    # Ligne saisie.
    class Line
      include Marten::Template::Object::Auto

      getter index : Int32
      getter description : String
      getter quantity : String
      getter price : String
      property errors : Array(String)? = nil

      def initialize(@index, @description = "", @quantity = "", @price = "")
      end

      def number : Int32
        index + 1
      end

      def blank : Bool
        description.empty? && price.empty?
      end

      def error_id : String
        "pd-ml#{index}-errors"
      end
    end

    def get
      require!(MODULE, WRITE)
      settings = Partiduo::Api::Micro.settings(current.actor)
      lines = (0...LINE_COUNT).map { |index| Line.new(index, quantity: index.zero? ? "1" : "") }
      show({"customer_id" => query("customer")}, lines, settings)
    end

    def post
      require!(MODULE, WRITE)
      settings = Partiduo::Api::Micro.settings(current.actor)
      values = %w[customer_id customer_name due_date vat_rate_id].to_h { |name| {name, field(name)} }
      lines = (0...LINE_COUNT).map do |index|
        Line.new(index, field("line-#{index}-description"), field("line-#{index}-quantity"), field("line-#{index}-price"))
      end
      errors = {} of String => Array(String)
      rate_id = rate_for(settings, values["vat_rate_id"])
      add(errors, "vat_rate_id", I18n.t("ui.forms.required")) if rate_id.nil?
      inputs = line_inputs(lines, rate_id)
      add(errors, "base", I18n.t("ui.micro.invoice.no_line")) if inputs.empty?
      due = values["due_date"].empty? ? nil : fmt.parse_date(values["due_date"])
      add(errors, "due_date", I18n.t("ui.forms.invalid_date")) if due.nil? && !values["due_date"].empty?
      # Le nouveau client n'est créé qu'une fois le reste de la saisie lisible.
      customer = customer_id(values, errors, lines.any?(&.errors))
      if errors.empty? && lines.none?(&.errors) && customer
        result = Inv.create_document(current.actor, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer,
          lines: inputs, due_date: due))
        if document = result.value?
          flash["success"] = I18n.t("ui.micro.invoice.created")
          return go(document_url(document))
        end
        place_errors(result.errors, lines, errors)
      end
      show(values, lines, settings, errors, 422)
    end

    private def add(errors : Hash(String, Array(String)), key : String, message : String) : Nil
      (errors[key] ||= [] of String) << message
    end

    # Lignes remplies, en désignations chiffrées (`free`) au taux `rate_id`.
    private def line_inputs(lines : Array(Line), rate_id : Int64?) : Array(Inv::LineInput)
      lines.reject(&.blank).map do |line|
        quantity = line.quantity.empty? ? BigDecimal.new(1) : fmt.parse_decimal(line.quantity)
        price = fmt.parse_decimal(line.price)
        line.errors = [I18n.t("ui.forms.invalid_number")] if quantity.nil? || price.nil?
        line.errors = [I18n.t("ui.micro.invoice.description_required")] if line.description.empty?
        Inv::LineInput.new(kind: "free", description: line.description, quantity: quantity || BigDecimal.new(1),
          unit_price: price, vat_rate_id: rate_id)
      end
    end

    # Erreurs du contrat : sous la ligne (`lines[n]…`), le client,
    # l'échéance, sinon l'ensemble.
    private def place_errors(found : Array(Partiduo::Api::FieldError), lines : Array(Line), errors : Hash(String, Array(String))) : Nil
      filled = lines.reject(&.blank)
      found.each do |error|
        if (match = error.field.match(/\Alines\[(\d+)\]/)) && (line = filled[match[1].to_i]?)
          line.errors = (line.errors || [] of String) << fmt.message(error)
          next
        end
        key = {"customer_card_id" => "customer_id", "due_date" => "due_date"}[error.field]? || "base"
        add(errors, key, fmt.message(error))
      end
    end

    # Client choisi, ou créé par son nom (fiche du socle de la catégorie
    # des clients) ; `nil` et une erreur sinon.
    private def customer_id(values : Hash(String, String), errors : Hash(String, Array(String)), pending : Bool) : Int64?
      if id = values["customer_id"].to_i64?
        return id
      end
      name = values["customer_name"]
      if name.empty?
        (errors["customer_id"] ||= [] of String) << I18n.t("ui.micro.invoice.customer_required")
        return
      end
      return if pending || !errors.empty?
      category = Partiduo::Api::Cards.categories(current.actor, "customer").first?
      if category.nil?
        (errors["customer_name"] ||= [] of String) << I18n.t("ui.micro.invoice.no_customer_category")
        return
      end
      result = Partiduo::Api::Cards.create_card(current.actor, Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: name))
      if card = result.value?
        values["customer_id"] = card.id.to_s
        values["customer_name"] = ""
        return card.id
      end
      result.errors.each { |error| (errors["customer_name"] ||= [] of String) << fmt.message(error) }
      nil
    rescue Partiduo::Api::Forbidden
      (errors["customer_name"] ||= [] of String) << I18n.t("ui.micro.invoice.customer_forbidden")
      nil
    end

    # Taux des lignes : franchise en base tant que la bascule vers la TVA
    # n'est pas notée, sinon le taux choisi.
    private def rate_for(settings : Partiduo::Api::Micro::SettingsView, chosen : String) : Int64?
      if settings.vat_liable_since.nil? && (franchise = franchise_rate)
        return franchise.id
      end
      id = chosen.to_i64?
      id && selectable_rates.any?(&.id.==(id)) ? id : nil
    end

    private def franchise_rate : Partiduo::Api::Vat::RateView?
      vat_rates.find { |rate| rate.enabled && rate.exemption_code == FRANCHISE }
    end

    private def selectable_rates : Array(Partiduo::Api::Vat::RateView)
      vat_rates.select { |rate| rate.enabled && rate.exemption_code != FRANCHISE && !rate.reverse_charge }
    end

    private def customers : Array(Partiduo::Api::Cards::CardView)
      Partiduo::Api::Cards.cards(current.actor, Partiduo::Api::Cards::CardQuery.new(kind: "customer", limit: 1000))
        .sort_by!(&.name.downcase)
    end

    private def show(values : Hash(String, String), lines : Array(Line), settings : Partiduo::Api::Micro::SettingsView,
                     errors = {} of String => Array(String), status : Int32 = 200) : Marten::HTTP::Response
      franchise = settings.vat_liable_since.nil? && !franchise_rate.nil?
      customer_options = [Form::Option.new("", I18n.t("ui.micro.invoice.new_customer"), values["customer_id"]?.to_s.empty?)] +
                         customers.map { |card| Form::Option.new(card.id.to_s, card.name, card.id.to_s == values["customer_id"]?) }
      default_rate = values["vat_rate_id"]?.presence || selectable_rates.select(&.category.==("S")).max_by?(&.rate).try(&.id.to_s) || ""
      rate_options = selectable_rates.map { |rate| Form::Option.new(rate.id.to_s, "#{rate.code} · #{fmt.percent(rate.rate)}", rate.id.to_s == default_rate) }
      context["title"] = I18n.t("ui.micro.invoice.title")
      context["crumbs"] = [crumb("ui.micro.menu.dashboard", reverse("core:dashboard")), crumb("ui.micro.menu.invoices", reverse("invoicing:documents"))]
      context["customer_name"] = values["customer_name"]? || ""
      context["due_date"] = values["due_date"]? || ""
      context["lines"] = lines
      context["customer_options"] = customer_options
      context["rate_options"] = franchise ? nil : rate_options
      context["franchise"] = franchise
      context["errors"] = errors
      context["customer_errors"] = errors["customer_id"]?
      context["customer_name_errors"] = errors["customer_name"]?
      context["due_errors"] = errors["due_date"]?
      context["rate_errors"] = errors["vat_rate_id"]?
      context["base_errors"] = errors["base"]?
      context["form_action"] = reverse("micro:invoice_new")
      context["full_url"] = SimpleMode.switch_target(request) ? reverse("invoicing:invoice_new") : nil
      page("ui/micro/invoice.html", status: status)
    end
  end
end
