# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Bons à facturer (menu `invoicing:to_invoice`, DECISIONS D-INV2-010) :
  # bons de livraison émis et non facturés, filtrés par client et par
  # période ; « Facturer ces bons » (sélection : facture d'un bon ou facture
  # récapitulative) ; « Facturer le mois » (tous les clients mensuels, ou un
  # client) ; factures de fin de mois proposées, émises et envoyées d'un clic,
  # une par une ou toutes. Encours HT et plafond de chaque client listé. Tout
  # passe par `Api::Invoicing`.
  class ToInvoiceHandler < InvoicingScreen
    # Ligne de la liste (gabarit `ui/invoicing/to_invoice.html`).
    class NoteRow
      include Marten::Template::Object::Auto

      getter id : Int64
      getter number : String
      getter url : String
      getter delivery_date : String
      getter customer : String
      getter customer_url : String?
      getter rhythm : String
      getter net : String
      getter gross : String
      getter exposure : String
      getter exposure_status : String?
      getter draft_url : String?
      getter checked : Bool # ameba:disable Naming/QueryBoolMethods

      def initialize(@id, @number, @url, @delivery_date, @customer, @customer_url, @rhythm, @net, @gross, @exposure,
                     @exposure_status, @draft_url, @checked)
      end

      def selectable : Bool
        draft_url.nil?
      end
    end

    # Facture de fin de mois proposée.
    class ProposalRow
      include Marten::Template::Object::Auto

      getter customer : String
      getter number : String
      getter url : String
      getter month : String
      getter gross : String
      getter error : String?
      getter send_url : String

      def initialize(@customer, @number, @url, @month, @gross, @error, @send_url)
      end
    end

    def get
      require!(MODULE, READ)
      show
    end

    # « Facturer ces bons » : brouillon de facture des bons cochés.
    def post
      require!(MODULE, WRITE)
      ids = (request.data.fetch_all("note", [] of String) || [] of String).compact_map(&.to_s.to_i64?).uniq!
      result = Inv.invoice_delivery_notes(current.actor, ids)
      if document = result.value?
        flash["success"] = I18n.t("ui.invoicing.to_invoice.created", count: ids.size)
        return go(reverse("invoicing:document", id: document.id))
      end
      show(ids, result.errors.map { |error| fmt.message(error) }, 422)
    end

    private def show(checked = [] of Int64, refused : Array(String)? = nil, status : Int32 = 200) : Marten::HTTP::Response
      actor = current.actor
      customer = query("customer").to_i64?
      from = fmt.parse_short_date(query("from"), Partiduo::Api::Core.today)
      upto = fmt.parse_short_date(query("to"), Partiduo::Api::Core.today)
      all = Inv.delivery_notes_to_invoice(actor)
      notes = Inv.delivery_notes_to_invoice(actor, Inv::ToInvoiceQuery.new(customer_card_id: customer, from: from, to: upto))
      billing = notes.map(&.customer_card_id).uniq!.to_h { |id| {id, Inv.customer_billing(actor, id)} }
      context["title"] = I18n.t("invoicing.menu.inv_to_invoice")
      context["crumbs"] = [crumb("core.menu.billing"), crumb("invoicing.menu.inv_to_invoice", reverse("invoicing:to_invoice"))]
      context["actions"] = [] of Screen::Action
      context["customers"] = customer_options(all, customer)
      context["from"] = query("from")
      context["to"] = query("to")
      context["refused"] = refused
      context["rows"] = listed(notes.map { |note| note_row(note, billing[note.customer_card_id], checked) })
      context["can_write"] = can?(WRITE)
      context["month"] = Partiduo::Api::Core.today.to_s("%Y-%m")
      context["customer_id"] = customer.try(&.to_s) || ""
      context["customer_filtered"] = !customer.nil?
      context["proposals"] = listed(proposals)
      context["can_issue"] = can?("invoicing.invoice.issue")
      context["total_net"] = fmt.amount(notes.sum(BigDecimal.new(0), &.total_net))
      context["total_gross"] = fmt.amount(notes.sum(BigDecimal.new(0), &.total_gross))
      page("ui/invoicing/to_invoice.html", status: status)
    end

    private def customer_options(all : Array(Inv::ToInvoiceView), selected : Int64?) : Array(Form::Option)
      customers = all.map { |note| {note.customer_card_id, note.customer_name} }.uniq!.sort_by!(&.[1])
      [Form::Option.new("", I18n.t("ui.invoicing.to_invoice.all_customers"), selected.nil?)] +
        customers.map { |(id, name)| Form::Option.new(id.to_s, name, id == selected) }
    end

    private def note_row(note : Inv::ToInvoiceView, billing : Inv::CustomerBillingView, checked : Array(Int64)) : NoteRow
      NoteRow.new(note.id, note.number, reverse("invoicing:document", id: note.id), fmt.date(note.delivery_date),
        note.customer_name, reverse("cards:show", id: note.customer_card_id),
        I18n.t("invoicing.billing_rhythms.#{note.billing_rhythm}"), fmt.amount(note.total_net), fmt.amount(note.total_gross),
        CustomerBillingDisplay.exposure_text(billing, fmt), CustomerBillingDisplay.status_text(billing),
        note.draft_invoice_id.try { |id| reverse("invoicing:document", id: id) }, checked.includes?(note.id))
    end

    private def proposals : Array(ProposalRow)
      Inv.monthly_proposals(current.actor).compact_map do |proposal|
        invoice_id = proposal.invoice_id || next
        error = proposal.error.presence.try do |keys|
          keys.split(", ").map { |key| key.includes?('.') ? I18n.t(key, default: key) : key }.join(" ")
        end
        ProposalRow.new(proposal.customer_name, I18n.t("ui.invoicing.draft"), reverse("invoicing:document", id: invoice_id),
          fmt.month(proposal.month), "#{fmt.amount(proposal.total_gross)} #{proposal.currency_code}", error,
          reverse("invoicing:document_issue_send", id: invoice_id))
      end
    end
  end

  # « Facturer le mois » : factures récapitulatives du mois (champ `month`,
  # `AAAA-MM`, défaut : mois en cours) pour tous les clients mensuels, ou
  # pour le client `customer` (champ, ou paramètre de l'action de la fiche
  # client, qui y revient).
  class MonthPrepareHandler < InvoicingScreen
    def post
      require!(MODULE, WRITE)
      today = Partiduo::Api::Core.today
      month = begin
        Time.parse_utc("#{field("month")}-01", "%Y-%m-%d")
      rescue Time::Format::Error
        today
      end
      from_card = query("customer").to_i64?
      customer = field("customer").to_i64? || from_card
      run = Inv.prepare_monthly_invoices(current.actor, Inv::MonthlyInput.new(month: month, customer_card_id: customer))
      failed = run.prepared.count(&.status.==("failed"))
      prepared = run.prepared.size - failed
      flash["success"] = I18n.t("ui.invoicing.to_invoice.month_prepared", count: prepared, month: fmt.month(month))
      flash["warning"] = I18n.t("ui.invoicing.to_invoice.month_failed", count: failed) if failed > 0
      go(from_card ? reverse("cards:show", id: from_card) : reverse("invoicing:to_invoice"))
    end
  end

  # Émettre et envoyer d'un clic une facture (proposée ou brouillon), selon
  # son canal : message de la suite donnée.
  class DocumentIssueSendHandler < InvoicingScreen
    def post
      result = Inv.issue_and_send(current.actor, id_param)
      if outcome = result.value?
        message = I18n.t("invoicing.dispatch.#{outcome.action}", to: outcome.detail)
        flash[outcome.action.in?("email_missing", "email_failed", "send_denied") ? "warning" : "success"] =
          "#{document_title(outcome.document)} : #{message}"
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(reverse("invoicing:to_invoice"))
    end
  end

  # Émettre et envoyer toutes les factures de fin de mois proposées.
  class ProposalsIssueSendHandler < InvoicingScreen
    def post
      results = Inv.issue_and_send_proposals(current.actor)
      done = results.count(&.success?)
      flash["success"] = I18n.t("ui.invoicing.to_invoice.all_sent", count: done)
      refused = results.select(&.failure?).flat_map(&.errors).map { |error| fmt.message(error) }.uniq!
      flash["danger"] = refused.join(" ") unless refused.empty?
      go(reverse("invoicing:to_invoice"))
    end
  end

  # Réglage client de la Facturation : rythme de facturation et encours
  # maximum HT (DECISIONS D-INV2-004, D-INV2-005).
  class CustomerBillingHandler < InvoicingScreen
    PERMISSION = "invoicing.settings.manage"

    def get
      require!(MODULE, PERMISSION)
      view = Inv.customer_billing(current.actor, id_param)
      show(view, billing_form(view.billing_rhythm, view.credit_limit.try { |limit| fmt.input_number(limit) } || ""))
    end

    def post
      require!(MODULE, PERMISSION)
      view = Inv.customer_billing(current.actor, id_param)
      errors = [] of {String, String}
      limit = decimal("credit_limit", errors)
      form = billing_form(field("billing_rhythm"), field("credit_limit"))
      if errors.empty?
        result = Inv.update_customer_billing(current.actor, view.customer_card_id,
          Inv::CustomerBillingInput.new(field("billing_rhythm"), limit))
        if result.success?
          flash["success"] = I18n.t("ui.invoicing.customer_billing.saved", name: view.customer_name)
          return go(reverse("cards:show", id: view.customer_card_id))
        end
        form.add_errors(result.errors, fmt)
      end
      errors.each { |(name, message)| form.add_error(name, message) }
      show(view, form)
    end

    private def billing_form(rhythm : String, limit : String) : Form
      rhythms = Inv::BILLING_RHYTHMS.map { |code| option(code, I18n.t("invoicing.billing_rhythms.#{code}")) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("billing_rhythm", I18n.t("ui.invoicing.customer_billing.rhythm"), "select", rhythm, options: rhythms,
          help: I18n.t("ui.invoicing.customer_billing.rhythm_help")),
        Form::Field.new("credit_limit", I18n.t("ui.invoicing.customer_billing.credit_limit"), "number", limit, mono: true,
          help: I18n.t("ui.invoicing.customer_billing.credit_limit_help")),
      ])])
    end

    private def show(view : Inv::CustomerBillingView, form : Form) : Marten::HTTP::Response
      card_url = reverse("cards:show", id: view.customer_card_id)
      form_page(I18n.t("ui.invoicing.customer_billing.title", name: view.customer_name),
        [crumb("core.menu.reference"), Screen::Crumb.new(view.customer_name, card_url)], form,
        reverse("invoicing:customer_billing", id: view.customer_card_id), I18n.t("ui.forms.save"), card_url,
        intro: I18n.t("ui.invoicing.customer_billing.intro"))
    end
  end

  # Rubrique « Facturation » de la fiche d'un client : rythme, encours HT et
  # plafond (jauge), bons non facturés ; actions selon les droits.
  module CustomerBillingDisplay
    alias Inv = Partiduo::Api::Invoicing

    # « 1 234,00 / 5 000,00 EUR » (plafond) ou « 1 234,00 EUR ».
    def self.exposure_text(view : Inv::CustomerBillingView, fmt : Format) : String
      if limit = view.credit_limit
        "#{fmt.amount(view.exposure)} / #{fmt.amount(limit)} #{view.currency_code}"
      else
        "#{fmt.amount(view.exposure)} #{view.currency_code}"
      end
    end

    # État en toutes lettres (jamais la seule couleur) : dépassé, proche.
    def self.status_text(view : Inv::CustomerBillingView) : String?
      if view.exceeded?
        I18n.t("ui.invoicing.customer_billing.exceeded")
      elsif view.near_limit?
        I18n.t("ui.invoicing.customer_billing.near_limit", percent: view.percent_used || 0)
      end
    end

    def self.gauge(view : Inv::CustomerBillingView, fmt : Format) : Screen::Gauge?
      limit = view.credit_limit || return
      percent = view.percent_used || (view.exposure > 0 ? 100 : 0)
      tone = view.exceeded? ? "gap" : (view.near_limit? ? "warn" : "ok")
      status = status_text(view) || I18n.t("ui.invoicing.customer_billing.within_limit")
      detail = I18n.t("ui.invoicing.customer_billing.gauge_detail", exposure: fmt.amount(view.exposure),
        limit: fmt.amount(limit), currency: view.currency_code)
      Screen::Gauge.new(I18n.t("ui.invoicing.customer_billing.exposure"), detail, status, fmt.percent(BigDecimal.new(percent)),
        percent.clamp(0, 100), tone)
    end

    def self.section(handler : ReferenceHandler, card : Partiduo::Api::Cards::CardView, fmt : Format) : Screen::Section
      view = Inv.customer_billing(handler.current.actor, card.id)
      items = [
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.rhythm"), I18n.t("invoicing.billing_rhythms.#{view.billing_rhythm}")),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.credit_limit"),
          view.credit_limit.try { |limit| "#{fmt.amount(limit)} #{view.currency_code}" } || I18n.t("ui.invoicing.customer_billing.no_limit"), mono: true),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.exposure"), "#{fmt.amount(view.exposure)} #{view.currency_code}", mono: true),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.unbilled"),
          I18n.t("ui.invoicing.customer_billing.unbilled_value", count: view.unbilled_count, net: fmt.amount(view.unbilled_net),
            gross: fmt.amount(view.unbilled_gross), currency: view.currency_code),
          "#{handler.reverse("invoicing:to_invoice")}?customer=#{card.id}"),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.receivable"), "#{fmt.amount(view.receivable_net)} #{view.currency_code}", mono: true),
      ]
      if view.unconverted > 0
        items << Screen::Item.new(I18n.t("ui.invoicing.customer_billing.unconverted_label"),
          I18n.t("ui.invoicing.customer_billing.unconverted", count: view.unconverted))
      end
      actions = [] of Screen::Action
      if handler.can?("invoicing.settings.manage")
        actions << Screen::Action.new(I18n.t("ui.forms.edit"), handler.reverse("invoicing:customer_billing", id: card.id), style: "small")
      end
      if handler.can?("invoicing.invoice.write") && view.unbilled_count > 0
        actions << Screen::Action.new(I18n.t("ui.invoicing.to_invoice.month_customer"),
          "#{handler.reverse("invoicing:month_prepare")}?customer=#{card.id}", "post", "small")
      end
      section = Screen::Section.new(I18n.t("ui.invoicing.customer_billing.section"), items, actions: actions)
      section.gauge = gauge(view, fmt)
      section
    end
  end
end
