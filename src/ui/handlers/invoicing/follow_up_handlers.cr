# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Suivi des factures : règlements (menu `invoicing:payments`), relances
  # (menu `invoicing:reminders`), transmission au comptable (menu
  # `invoicing:export`). Tout passe par `Api::Invoicing`.
  abstract class FollowUpScreen < InvoicingScreen
    OPEN_KINDS = %w[invoice deposit_invoice]

    # Factures et acomptes émis non soldés, de l'échéance la plus ancienne à
    # la plus récente ; `customer` : d'un seul client.
    def open_invoices(customer : Int64? = nil) : Array(Inv::DocumentView)
      OPEN_KINDS.flat_map do |kind|
        Inv.documents(current.actor, Inv::DocumentQuery.new(kind: kind, customer_card_id: customer, limit: 500))
      end.select { |document| !document.draft? && document.totals.amount_due.positive? && document.effective_status != "cancelled" }
        .sort_by! { |document| {document.due_date || document.issue_date || document.created_at, document.id} }
    end
  end

  # Factures à encaisser ; règlement saisi quand la Comptabilité est
  # inactive (sinon il vient du lettrage, D-INV-009).
  class PaymentsHandler < FollowUpScreen
    def get
      require!(MODULE, "invoicing.payment.record")
      accounting = module_active?("ACCOUNTING")
      columns = [
        Table::Column.new("number", I18n.t("ui.invoicing.number"), "mono"),
        Table::Column.new("customer", I18n.t("ui.invoicing.customer")),
        Table::Column.new("due", I18n.t("ui.invoicing.due_date"), "mono", secondary: true),
        Table::Column.new("gross", I18n.t("ui.invoicing.gross"), "amount", secondary: true),
        Table::Column.new("left", I18n.t("ui.invoicing.left"), "amount"),
        Table::Column.new("status", I18n.t("ui.invoicing.status"), secondary: true),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = open_invoices.map do |document|
        due = document.totals.amount_due
        actions = accounting ? nil : [link_action("ui.invoicing.record_payment", reverse("invoicing:document_payment", id: document.id), "small")]
        Table::Row.new([
          Table::Cell.new(document.number || "", document_url(document)),
          Table::Cell.new(document.customer.name),
          Table::Cell.new(fmt.date(document.due_date), sort: date_key(document.due_date), csv: date_key(document.due_date)),
          Table::Cell.new(fmt.amount(document.totals.total_gross), sort: document.totals.total_gross, csv: fmt.csv_amount(document.totals.total_gross)),
          Table::Cell.new(fmt.amount(due), sort: due, csv: fmt.csv_amount(due)),
          Table::Cell.new(status_label(document.effective_status)),
          Table::Cell.new("", actions: actions),
        ], document.effective_status == "overdue" ? "pd-row-late" : "")
      end
      table = Table.new(I18n.t("invoicing.menu.inv_payments"), columns, rows, reverse("invoicing:payments"),
        empty_message: I18n.t("ui.invoicing.nothing_due"))
      intro = accounting ? I18n.t("ui.invoicing.payment_by_matching") : nil
      list_page(I18n.t("invoicing.menu.inv_payments"), table, [crumb("core.menu.billing")], "ui.invoicing.payments_csv", intro: intro)
    end
  end

  # Saisie d'un règlement (partiel ou total) sur une facture.
  class DocumentPaymentHandler < FollowUpScreen
    def get
      require!(MODULE, "invoicing.payment.record")
      document = Inv.document(current.actor, id_param)
      show(document, payment_form(document))
    end

    def post
      require!(MODULE, "invoicing.payment.record")
      document = Inv.document(current.actor, id_param)
      errors = [] of {String, String}
      amount = decimal("amount", errors, required: true)
      paid_on = fmt.parse_short_date(field("paid_on"), Partiduo::Api::Core.today)
      errors << {"paid_on", I18n.t("ui.forms.invalid_date")} unless paid_on
      method = Inv::PAYMENT_METHODS.includes?(field("method")) ? field("method") : "transfer"
      form = payment_form(document)
      %w[amount paid_on method reference].each { |name| form.fields.find(&.name.==(name)).try(&.value=(field(name))) }
      if errors.empty? && amount && paid_on
        input = Inv::PaymentInput.new(document.id, amount, paid_on, method, field("reference").presence)
        result = Inv.record_payment(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("ui.invoicing.payment_recorded", amount: fmt.amount(amount))
          return go(document_url(document))
        end
        form.add_errors(result.errors, fmt)
      end
      errors.each { |(name, message)| form.add_error(name, message) }
      show(document, form)
    end

    private def payment_form(document : Inv::DocumentView) : Form
      methods = Inv::PAYMENT_METHODS.map { |code| option(code, I18n.t("ui.invoicing.methods.#{code}")) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("amount", I18n.t("ui.invoicing.payment_amount"), "number", fmt.input_number(document.totals.amount_due), required: true, mono: true),
        Form::Field.new("paid_on", I18n.t("ui.invoicing.paid_on"), value: fmt.date(Partiduo::Api::Core.today), required: true, mono: true,
          help: I18n.t("ui.invoicing.date_help")),
        Form::Field.new("method", I18n.t("ui.invoicing.method"), "select", "transfer", options: methods),
        Form::Field.new("reference", I18n.t("ui.invoicing.payment_reference")),
      ])])
    end

    private def show(document : Inv::DocumentView, form : Form) : Marten::HTTP::Response
      intro = module_active?("ACCOUNTING") ? I18n.t("ui.invoicing.payment_by_matching") : I18n.t("ui.invoicing.left_to_pay", amount: fmt.amount(document.totals.amount_due))
      form_page(I18n.t("ui.invoicing.payment_title", title: document_title(document)),
        crumbs + [Screen::Crumb.new(document_title(document), document_url(document))], form,
        reverse("invoicing:document_payment", id: document.id), I18n.t("ui.invoicing.record_payment"), document_url(document),
        intro: intro)
    end
  end

  # Envoi d'un document émis par courriel (PDF Factur-X joint) : adresse du
  # client proposée, textes par défaut dans la langue du document si les
  # champs restent vides. L'envoi est tracé, même en échec.
  class DocumentSendHandler < FollowUpScreen
    PERMISSION = "invoicing.invoice.send"

    def get
      require!(MODULE, PERMISSION)
      document = Inv.document(current.actor, id_param)
      show(document, send_form(document))
    end

    def post
      require!(MODULE, PERMISSION)
      document = Inv.document(current.actor, id_param)
      form = send_form(document)
      %w[to cc subject body].each { |name| form.fields.find(&.name.==(name)).try(&.value=(field(name, strip: name != "body"))) }
      input = Inv::SendInput.new(to: addresses("to"), cc: addresses("cc"), subject: field("subject").presence,
        body: field("body", strip: false).strip.presence)
      result = Inv.send_document(current.actor, document.id, input)
      if log = result.value?
        flash["success"] = I18n.t("ui.invoicing.sent_by_email", to: log.recipients.join(", "))
        return go(document_url(document))
      end
      form.add_errors(result.errors, fmt)
      show(document, form)
    end

    private def addresses(name : String) : Array(String)
      field(name).split(/[,;\s]+/).map(&.strip).reject(&.empty?)
    end

    private def send_form(document : Inv::DocumentView) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("to", I18n.t("ui.invoicing.mail_to"), "text", document.customer.email, wide: true,
          help: I18n.t("ui.invoicing.mail_to_help")),
        Form::Field.new("cc", I18n.t("ui.invoicing.mail_cc"), "text", wide: true),
        Form::Field.new("subject", I18n.t("ui.invoicing.mail_subject"), wide: true, maxlength: 255,
          placeholder: I18n.t("ui.invoicing.mail_default")),
        Form::Field.new("body", I18n.t("ui.invoicing.mail_body"), "textarea", wide: true,
          placeholder: I18n.t("ui.invoicing.mail_default")),
      ])])
    end

    private def show(document : Inv::DocumentView, form : Form) : Marten::HTTP::Response
      form_page(I18n.t("ui.invoicing.send_title", title: document_title(document)),
        crumbs + [Screen::Crumb.new(document_title(document), document_url(document))], form,
        reverse("invoicing:document_send", id: document.id), I18n.t("ui.invoicing.send"), document_url(document),
        intro: I18n.t("ui.invoicing.send_intro"))
    end
  end

  # Relances proposées (« À traiter ») : proposer, envoyer, écarter. Rien
  # n'est envoyé d'office (D-INV-011).
  class RemindersHandler < FollowUpScreen
    PERMISSION = "invoicing.reminder.send"

    def get
      require!(MODULE, PERMISSION)
      reminders = Inv.reminders(current.actor)
      customer = query("customer").to_i64?
      if customer
        ids = open_invoices(customer).map(&.id).to_set
        reminders = reminders.select { |reminder| ids.includes?(reminder.document_id) }
      end
      columns = [
        Table::Column.new("number", I18n.t("ui.invoicing.number"), "mono"),
        Table::Column.new("customer", I18n.t("ui.invoicing.customer")),
        Table::Column.new("level", I18n.t("ui.invoicing.reminder_level"), "mono"),
        Table::Column.new("late", I18n.t("ui.invoicing.days_late"), "amount", secondary: true),
        Table::Column.new("balance", I18n.t("ui.invoicing.left"), "amount", secondary: true),
        Table::Column.new("penalties", I18n.t("ui.invoicing.penalties"), "amount", secondary: true),
        Table::Column.new("total", I18n.t("ui.invoicing.claimed"), "amount"),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = reminders.map do |reminder|
        penalties = reminder.interest + reminder.indemnity
        Table::Row.new([
          Table::Cell.new(reminder.document_number, reverse("invoicing:document", id: reminder.document_id)),
          Table::Cell.new(reminder.customer_name),
          Table::Cell.new(reminder.level.to_s, sort: reminder.level.to_s),
          Table::Cell.new(reminder.days_late.to_s, sort: BigDecimal.new(reminder.days_late)),
          Table::Cell.new(fmt.amount(reminder.balance), sort: reminder.balance, csv: fmt.csv_amount(reminder.balance)),
          Table::Cell.new(fmt.amount(penalties), sort: penalties, csv: fmt.csv_amount(penalties)),
          Table::Cell.new(fmt.amount(reminder.total_claimed), sort: reminder.total_claimed, csv: fmt.csv_amount(reminder.total_claimed)),
          Table::Cell.new("", actions: [
            post_action("ui.invoicing.send_reminder", reverse("invoicing:reminder_send", id: reminder.id), "ui.invoicing.send_reminder_confirm", "small"),
            post_action("ui.invoicing.dismiss_reminder", reverse("invoicing:reminder_dismiss", id: reminder.id), style: "small"),
          ]),
        ])
      end
      params = customer ? {"customer" => customer.to_s} : {} of String => String
      table = Table.new(I18n.t("invoicing.menu.inv_reminders"), columns, rows, reverse("invoicing:reminders"), params,
        empty_message: I18n.t("ui.invoicing.no_reminder"))
      actions = [post_action("ui.invoicing.propose_reminders", reverse("invoicing:reminders_propose"), style: "primary", icon: "clock")]
      list_page(I18n.t("invoicing.menu.inv_reminders"), table, [crumb("core.menu.billing")], "ui.invoicing.reminders_csv", actions,
        intro: I18n.t("ui.invoicing.reminders_intro"))
    end
  end

  class RemindersProposeHandler < FollowUpScreen
    def post
      require!(MODULE, RemindersHandler::PERMISSION)
      proposed = Inv.propose_reminders(current.actor)
      flash["success"] = I18n.t("ui.invoicing.reminders_proposed", count: proposed.size)
      go(reverse("invoicing:reminders"))
    end
  end

  class ReminderSendHandler < FollowUpScreen
    def post
      result = Inv.send_reminder(current.actor, id_param)
      if reminder = result.value?
        flash["success"] = I18n.t("ui.invoicing.reminder_sent", number: reminder.document_number)
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(reverse("invoicing:reminders"))
    end
  end

  class ReminderDismissHandler < FollowUpScreen
    def post
      result = Inv.dismiss_reminder(current.actor, id_param)
      if reminder = result.value?
        flash["success"] = I18n.t("ui.invoicing.reminder_dismissed", number: reminder.document_number)
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(reverse("invoicing:reminders"))
    end
  end

  # Transmission au comptable (Facturation seule, D-INV-013) : journal des
  # ventes et des encaissements (CSV), FEC des ventes, archive des PDF.
  class ExportHandler < FollowUpScreen
    PERMISSION = "invoicing.export.read"

    def get
      require!(MODULE, PERMISSION)
      today = Partiduo::Api::Core.today
      from = fmt.parse_short_date(query("from"), today) || Time.utc(today.year, today.month, 1)
      to = fmt.parse_short_date(query("to"), today) || Time.utc(from.year, from.month, Time.days_in_month(from.year, from.month))
      errors = [] of Partiduo::Api::FieldError
      if format = {"csv", "fec", "zip"}.find(&.==(query("format")))
        file = case format
               when "csv" then Inv.sales_journal_csv(current.actor, from, to)
               when "fec"
                 # FEC en devise de tenue : refusé sans cours pour un document
                 # en devise étrangère (D-2F-009).
                 result = Inv.sales_fec(current.actor, from, to)
                 errors = result.errors
                 result.value?
               else Inv.pdf_archive(current.actor, from, to)
               end
        if file
          response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
          response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
          return response
        end
      end
      form = Form.new([Form::Group.new(nil, [
        Form::Field.new("from", I18n.t("ui.accounts.from"), value: fmt.date(from), mono: true, required: true),
        Form::Field.new("to", I18n.t("ui.accounts.to"), value: fmt.date(to), mono: true, required: true),
        Form::Field.new("format", I18n.t("ui.invoicing.export_format"), "select", query("format").presence || "csv", options: [
          option("csv", I18n.t("ui.invoicing.export_formats.csv")),
          option("fec", I18n.t("ui.invoicing.export_formats.fec")),
          option("zip", I18n.t("ui.invoicing.export_formats.zip")),
        ]),
      ])])
      form.add_errors(errors, fmt) unless errors.empty?
      context["form_method"] = "get"
      form_page(I18n.t("invoicing.menu.inv_export"), [crumb("core.menu.billing")], form, reverse("invoicing:export"),
        I18n.t("ui.invoicing.export_download"), intro: I18n.t("ui.invoicing.export_intro"))
    end
  end
end
