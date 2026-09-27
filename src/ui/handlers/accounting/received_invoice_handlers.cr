# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Facture d'achat reçue hors plateforme (ADR-004 D9 ; menu
  # `accounting:entry_received`) : facture papier ou PDF simple saisie dans le
  # journal d'achats, la pièce jointe à côté (disposition de la maquette pour
  # « Facture reçue ») — numéro et date de la facture du fournisseur, fichier
  # joint, aperçu. Enregistrement par `Api::Accounting.post_received_invoice`,
  # qui marque la facture « reçue hors plateforme » et refuse un doublon
  # (même fournisseur, même numéro, même montant) ; retour instantané par
  # `check_received_invoice`.
  #
  # Le fichier se dépose dès qu'il est choisi (HTMX, `entry_received_upload`)
  # et s'affiche à côté ; sans JavaScript, il part avec le formulaire. Une
  # fois déposé, il est gardé (`attachment_id`) si la saisie est refusée.
  module ReceivedInvoiceScreen
    # Champs propres à la facture reçue, hors de l'écriture.
    class Panel
      include Marten::Template::Object::Auto

      FIELDS = %w[invoice_number invoice_date attachment_id]

      property invoice_number : String = ""
      property invoice_date : String = ""
      property attachment_id : String = ""
      property attachment : Attachment? = nil
      @errors = {} of String => Array(String)

      def self.read(values : Hash(String, String)) : self
        panel = new
        panel.invoice_number = values["invoice_number"]?.to_s.strip
        panel.invoice_date = values["invoice_date"]?.to_s.strip
        panel.attachment_id = values["attachment_id"]?.to_s.strip
        panel
      end

      # Champ du contrat → champ du panneau ; `nil` pour ceux de l'écriture.
      def self.panel_field(field : String) : String?
        case field
        when "number"        then "invoice_number"
        when "invoice_date"  then "invoice_date"
        when "attachment_id" then "attachment_id"
        end
      end

      def add_error(field : String, message : String) : Nil
        (@errors[field] ||= [] of String) << message
      end

      def invalid : Bool
        !@errors.empty?
      end

      def invoice_number_errors : Array(String)?
        @errors["invoice_number"]?
      end

      def invoice_date_errors : Array(String)?
        @errors["invoice_date"]?
      end

      def attachment_errors : Array(String)?
        @errors["attachment_id"]?
      end

      def messages : Array(String)
        @errors.values.flatten
      end
    end

    # Pièce jointe affichée à côté de la saisie.
    class Attachment
      include Marten::Template::Object::Auto

      getter id : Int64
      getter filename : String
      getter url : String
      # `pdf` ou `image` : forme de l'aperçu.
      getter preview : String
      getter size : String

      def initialize(view : Partiduo::Api::Core::AttachmentView, @url : String)
        @id = view.id
        @filename = view.filename
        @preview = view.content_type == "application/pdf" ? "pdf" : "image"
        @size = I18n.t("ui.units.kilobytes", size: (view.byte_size / 1024.0).ceil.to_i)
      end
    end

    # Type déclaré d'un fichier déposé, d'après son extension (le socle
    # vérifie la signature du contenu).
    def self.content_type(filename : String) : String
      case File.extname(filename).downcase
      when ".pdf"          then "application/pdf"
      when ".png"          then "image/png"
      when ".jpg", ".jpeg" then "image/jpeg"
      else                      "application/octet-stream"
      end
    end
  end

  # Écran de saisie.
  class ReceivedInvoiceHandler < EntryScreen
    alias Panel = ReceivedInvoiceScreen::Panel

    def default_kind : String
      "purchase"
    end

    def title : String
      I18n.t("ui.received_invoice.title")
    end

    # Pas de ventilation dans cette saisie : l'écriture se ventile ensuite
    # depuis sa consultation (D-UI-057).
    def analytic_choices : EntryAnalytic::Choices?
      nil
    end

    def analytic_warning? : Bool
      module_active?("ANALYTIC") && Partiduo::Api::Analytic.distribution_required?(current.actor)
    rescue Partiduo::Api::AccessDenied
      false
    end

    def get
      require!("ACCOUNTING", PERMISSION)
      show_received(blank_form, Panel.new)
    end

    def post
      require!("ACCOUNTING", PERMISSION)
      values = form_values
      form = EntryForm.read("purchase", values)
      panel = Panel.read(values)
      if field("add_line") == "1"
        form.add_line
        return show_received(form, panel)
      end
      if index = field("remove_line").to_i?
        form.remove_line(index)
        return show_received(form.renumber!, panel)
      end
      upload(panel)
      input = received_input(form, panel)
      return show_received(form, panel, 422) unless input
      result = Acc.post_received_invoice(current.actor, input)
      if view = result.value?
        flash["success"] = I18n.t("ui.received_invoice.saved", number: view.number, receipt: view.receipt || "")
        return go(reverse("accounting:entry", id: view.entry_id))
      end
      result.errors.each do |error|
        if name = Panel.panel_field(error.field)
          panel.add_error(name, fmt.message(error))
        else
          form.add_error(error.field, fmt.message(error))
        end
      end
      show_received(form, panel, 422)
    end

    # Fichier envoyé avec le formulaire (sans JavaScript) : déposé au socle.
    private def upload(panel : Panel) : Nil
      # Déjà déposé (HTMX, ou envoi précédent refusé) : le fichier resté dans
      # le champ n'est pas déposé une seconde fois.
      return unless panel.attachment_id.empty?
      file = request.data["attachment_file"]?
      return unless file.is_a?(Marten::HTTP::UploadedFile) && file.size > 0
      result = ReceivedInvoiceUpload.store(current.actor, file)
      if view = result.value?
        panel.attachment_id = view.id.to_s
      else
        result.errors.each { |error| panel.add_error("attachment_id", fmt.message(error)) }
      end
    end

    # Facture saisie ; `nil` si un champ de l'interface est illisible.
    def received_input(form : EntryForm, panel : Panel) : Acc::ReceivedInvoiceInput?
      date = panel.invoice_date.empty? ? nil : fmt.parse_short_date(panel.invoice_date, reference_day)
      panel.add_error("invoice_date", I18n.t("ui.forms.invalid_date")) if !panel.invoice_date.empty? && date.nil?
      document = entry_input(form)
      return if panel.invalid || !document.is_a?(Acc::DocumentInput)
      document = document.copy_with(attachment_id: panel.attachment_id.to_i64?)
      Acc::ReceivedInvoiceInput.new(document: document, number: panel.invoice_number, invoice_date: date)
    end

    def show_received(form : EntryForm, panel : Panel, status : Int32 = 200) : Marten::HTTP::Response
      panel.attachment = ReceivedInvoiceUpload.attachment(self, panel.attachment_id.to_i64?)
      context["title"] = title
      context["crumbs"] = crumbs
      context["form"] = decorate(form)
      context["panel"] = panel
      context["kind"] = "purchase"
      context["no_ledger"] = writable_ledgers.empty?
      context["analytic_warning"] = analytic_warning?
      context["form_action"] = reverse("accounting:entry_received")
      page("ui/entries/received.html", status: status)
    end
  end

  # Retour instantané (HTMX) : écriture calculée et refus de
  # `check_received_invoice` (doublon compris). La pièce jointe manquante
  # n'est signalée qu'à l'enregistrement.
  class ReceivedInvoiceCheckHandler < EntryCheckHandler
    alias Panel = ReceivedInvoiceScreen::Panel

    def default_kind : String
      "purchase"
    end

    def post
      require!("ACCOUNTING", PERMISSION)
      values = form_values
      form = EntryForm.read("purchase", values)
      panel = Panel.read(values)
      check = EntryCheck.new(fmt)
      document = entry_input(form)
      if document.is_a?(Acc::DocumentInput)
        date = panel.invoice_date.empty? ? nil : fmt.parse_short_date(panel.invoice_date, reference_day)
        input = Acc::ReceivedInvoiceInput.new(document: document.copy_with(attachment_id: panel.attachment_id.to_i64?),
          number: panel.invoice_number, invoice_date: date)
        result = Acc.check_received_invoice(current.actor, input)
        errors = result.errors.reject do |error|
          error.key == "accounting.errors.received_invoice.attachment.required" ||
            (error.key == "accounting.errors.received_invoice.number.blank" && panel.invoice_number.empty?)
        end
        if view = result.value?
          check.draft(view, document: true)
        elsif errors.empty?
          # Seuls le numéro vide ou la pièce manquante bloquent : l'écriture
          # calculée s'affiche quand même.
          Acc.check_document(current.actor, document).value?.try { |draft| check.draft(draft, document: true) }
        end
        errors.each do |error|
          name = Panel.panel_field(error.field)
          name ? panel.add_error(name, fmt.message(error)) : form.add_error(error.field, fmt.message(error))
        end
      end
      messages = collect_errors(form).try(&.dup) || [] of String
      messages.concat(panel.messages)
      check.errors = messages.empty? ? nil : messages
      check.date_hint = form.date_hint
      check.due_date_hint = form.due_date_hint
      render("ui/entries/_check.html", {"check" => check, "kind" => "purchase"})
    end
  end

  # Dépôt du fichier dès qu'il est choisi (HTMX) : aperçu et identifiant
  # gardé dans le formulaire.
  class ReceivedInvoiceUploadHandler < ReferenceHandler
    def post
      require!("ACCOUNTING", "accounting.entry.post")
      file = request.data["attachment_file"]?
      attachment = nil
      errors = [] of String
      if file.is_a?(Marten::HTTP::UploadedFile) && file.size > 0
        result = ReceivedInvoiceUpload.store(current.actor, file)
        if view = result.value?
          attachment = ReceivedInvoiceUpload.attachment(self, view.id)
        else
          errors = result.errors.map { |error| fmt.message(error) }
        end
      else
        errors << I18n.t("ui.received_invoice.no_file")
      end
      render("ui/entries/_received_attachment.html", {
        "attachment" => attachment, "attachment_errors" => errors.empty? ? nil : errors,
      })
    end
  end

  module ReceivedInvoiceUpload
    def self.store(actor : Partiduo::Api::Actor,
                   file : Marten::HTTP::UploadedFile) : Partiduo::Api::Result(Partiduo::Api::Core::AttachmentView)
      filename = File.basename(file.filename.to_s)
      File.open(file.io.path) do |io|
        Partiduo::Api::Core.store_attachment(actor, Partiduo::Api::Core::AttachmentInput.new(filename,
          ReceivedInvoiceScreen.content_type(filename), io))
      end
    rescue Partiduo::Api::Forbidden
      Partiduo::Api::Result(Partiduo::Api::Core::AttachmentView).failure(
        Partiduo::Api::FieldError.new("attachment_id", "ui.received_invoice.upload_forbidden"))
    end

    # Pièce jointe lisible par l'acteur, `nil` sinon.
    def self.attachment(handler : ReferenceHandler, id : Int64?) : ReceivedInvoiceScreen::Attachment?
      return unless id
      view = Partiduo::Api::Core.attachment(handler.current.actor, id)
      ReceivedInvoiceScreen::Attachment.new(view, handler.reverse("core:attachment", id: id))
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      nil
    end
  end

  # Contenu d'une pièce jointe du socle, affiché dans la page (aperçu d'une
  # facture reçue) : `core.attachment.read`.
  class AttachmentHandler < ReferenceHandler
    # Types affichés dans la page. Les autres (XML, texte, CSV) sont
    # téléchargés : un XML servi en ligne sur l'origine de l'instance
    # pourrait porter du XHTML et son script (DECISIONS D-UI-059).
    INLINE_TYPES = %w[application/pdf image/png image/jpeg image/webp]

    def get
      actor = current.actor
      view = Partiduo::Api::Core.attachment(actor, id_param)
      content = Partiduo::Api::Core.attachment_content(actor, view.id)
      response = Marten::HTTP::Response.new(content: String.new(content), content_type: view.content_type)
      disposition = INLINE_TYPES.includes?(view.content_type) ? "inline" : "attachment"
      response["Content-Disposition"] = %(#{disposition}; filename="#{view.filename.gsub(/["\\[:cntrl:]]/, "")}")
      response["X-Content-Type-Options"] = "nosniff"
      # Aperçu dans un cadre de la même origine seulement.
      response["X-Frame-Options"] = "SAMEORIGIN"
      response["Cache-Control"] = "private, max-age=300"
      response
    end
  end
end
