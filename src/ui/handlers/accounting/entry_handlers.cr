# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Saisie d'une écriture (menus `accounting:entry_purchase`, `entry_sale`,
  # `entry_financial`, `entry_misc`), entièrement au clavier (ADR-005 D5) :
  # le formulaire est un formulaire HTML ordinaire (utilisable sans
  # JavaScript), HTMX tient l'équilibre et les totaux à jour par la requête
  # de contrôle du contrat (`check_entry`, `check_document`,
  # `check_financial`) et complète comptes et fiches ; le paquet Opal
  # `entry.js` ajoute les touches (Entrée, Alt+↓, Ctrl+Entrée, DECISIONS
  # D-UI-027).
  abstract class EntryScreen < ReferenceHandler
    alias Acc = Partiduo::Api::Accounting

    PERMISSION = "accounting.entry.post"

    def entry_kind : String
      kind = params["kind"]?.try(&.to_s) || default_kind
      raise Partiduo::Api::NotFound.new("entry_kind", kind) unless EntryForm::KINDS.includes?(kind)
      kind
    end

    def default_kind : String
      "misc"
    end

    def ledger_kind : Acc::LedgerKind
      Acc::LedgerKind.from_code(entry_kind)
    end

    def title : String
      I18n.t("ui.entries.titles.#{entry_kind}")
    end

    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.entry")]
    end

    # Journaux du type où l'acteur peut écrire (droit `W`, D-ACC-005).
    def writable_ledgers : Array(Acc::LedgerView)
      @writable_ledgers ||= Acc.ledgers(current.actor, ledger_kind, enabled_only: true).select(&.access.write?)
    end

    @writable_ledgers : Array(Acc::LedgerView)?
    @working_period : Partiduo::Api::Core::PeriodView?
    @working_period_read = false

    def working_period : Partiduo::Api::Core::PeriodView?
      return @working_period if @working_period_read
      @working_period_read = true
      @working_period = begin
        Shell.working_period(request, current.actor)
      rescue Partiduo::Api::AccessDenied
        nil
      end
    end

    # Référence de la saisie abrégée des dates : le mois de la période de
    # travail (barre supérieure), à défaut le mois courant.
    def reference_day : Time
      today = Partiduo::Api::Core.today
      period = working_period
      return today unless period
      period.includes?(today) ? today : period.starts_on
    end

    def form_values : Hash(String, String)
      request.data.to_h { |(name, values)| {name, values.last?.to_s} }
    end

    def vat_options(selected : String) : Array(Form::Option)
      rates = Partiduo::Api::Vat.rates(current.actor)
      [Form::Option.new("", I18n.t("ui.entries.no_vat"), selected.empty?)] +
        rates.map { |rate| Form::Option.new(rate.code, "#{rate.code} · #{fmt.percent(rate.rate)}", rate.code == selected) }
    end

    # Complète le formulaire pour l'affichage : journaux, taux, pièce
    # suivante.
    def decorate(form : EntryForm) : EntryForm
      ledgers = writable_ledgers
      form.ledger_id = ledgers.first?.try(&.id.to_s) || "" if form.ledger_id.empty?
      form.ledger_options = ledgers.map { |ledger| Form::Option.new(ledger.id.to_s, "#{ledger.code} · #{ledger.name}", ledger.id.to_s == form.ledger_id) }
      form.receipt_placeholder = ledgers.find { |ledger| ledger.id.to_s == form.ledger_id }.try(&.next_receipt) || ""
      if form.document
        options = vat_options("")
        form.each_row do |line|
          line.vat_options = options.map { |option| Form::Option.new(option.value, option.label, option.value == line.vat_rate) }
        end
      end
      form
    end

    def blank_form : EntryForm
      form = EntryForm.blank(entry_kind, entry_kind == "misc" ? 3 : 2)
      form.date = fmt.date(reference_day)
      ledger = query("ledger")
      form.ledger_id = ledger if writable_ledgers.any? { |item| item.id.to_s == ledger }
      form.date = query("date") unless query("date").empty?
      form
    end

    def show(form : EntryForm, status : Int32 = 200) : Marten::HTTP::Response
      context["title"] = title
      context["crumbs"] = crumbs
      context["form"] = decorate(form)
      context["kind"] = entry_kind
      context["no_ledger"] = writable_ledgers.empty?
      context["check"] = nil
      context["form_action"] = request.path
      page("ui/entries/form.html", status: status)
    end

    # --- Lecture de la saisie ----------------------------------------------------

    # Contrepartie d'une ligne : un code de fiche (quick code) s'il en existe
    # un de ce nom, sinon un numéro de compte (le contrat refuse un compte
    # inconnu).
    def card_code?(text : String) : String?
      return if text.empty? || text.matches?(/\A[0-9]+\z/)
      Partiduo::Api::Cards.card_by_code(current.actor, text).try(&.code)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    def parse_amount(text : String, line : EntryForm::Line, errors : Bool = true) : BigDecimal?
      return if text.empty?
      value = fmt.parse_decimal(text)
      line.add_error(I18n.t("ui.forms.invalid_number")) if value.nil? && errors
      value
    end

    # Date de l'en-tête (saisie abrégée) ; erreur sous le champ.
    def parse_day(form : EntryForm, name : String, text : String, required : Bool) : Time?
      if text.empty?
        form.add_error(name, I18n.t("ui.forms.required")) if required
        return
      end
      value = fmt.parse_short_date(text, reference_day)
      form.add_error(name, I18n.t("ui.forms.invalid_date")) unless value
      value
    end

    def ledger_id(form : EntryForm) : Int64?
      id = form.ledger_id.to_i64?
      form.add_error("ledger_id", I18n.t("ui.forms.required")) unless id
      id
    end

    def misc_lines(form : EntryForm) : Array(Acc::EntryLineInput)
      form.filled_lines.compact_map do |line|
        debit = parse_amount(line.debit, line)
        credit = parse_amount(line.credit, line)
        if debit && credit && !debit.zero? && !credit.zero?
          line.add_error(I18n.t("ui.entries.errors.both_sides"))
          next
        end
        side, amount = credit && !credit.zero? ? {Acc::Side::Credit, credit} : {Acc::Side::Debit, debit || BigDecimal.new(0)}
        card = card_code?(line.account)
        Acc::EntryLineInput.new(card ? "" : line.account, side, amount, card, line.label)
      end
    end

    def document_lines(form : EntryForm) : Array(Acc::DocumentLineInput)
      form.filled_lines.map do |line|
        amount = parse_amount(line.amount, line) || BigDecimal.new(0)
        item = card_code?(line.account)
        Acc::DocumentLineInput.new(amount: amount, item: item, account: item ? nil : line.account.presence,
          vat_rate: line.vat_rate.presence, label: line.label)
      end
    end

    def financial_lines(form : EntryForm) : Array(Acc::PaymentLineInput)
      form.filled_lines.compact_map do |line|
        receipt = parse_amount(line.debit, line)
        payment = parse_amount(line.credit, line)
        if receipt && payment && !receipt.zero? && !payment.zero?
          line.add_error(I18n.t("ui.entries.errors.both_sides"))
          next
        end
        amount = payment && !payment.zero? ? -payment : (receipt || BigDecimal.new(0))
        card = card_code?(line.account)
        Acc::PaymentLineInput.new(amount, card: card, account: card ? nil : line.account.presence, label: line.label)
      end
    end

    # Écriture saisie, pour le contrôle et l'enregistrement : `nil` si un
    # champ de l'interface est illisible (erreurs déjà rangées).
    def entry_input(form : EntryForm) : Acc::EntryInput | Acc::DocumentInput | Acc::FinancialInput?
      ledger = ledger_id(form)
      date = parse_day(form, "date", form.date, required: true)
      form.date_hint = date.try { |day| fmt.date(day) }
      case entry_kind
      when "misc"
        lines = misc_lines(form)
        return if form.invalid || ledger.nil? || date.nil?
        Acc::EntryInput.new(ledger_id: ledger, date: date, lines: lines, label: form.label, receipt: form.receipt.presence)
      when "financial"
        lines = financial_lines(form)
        return if form.invalid || ledger.nil? || date.nil?
        Acc::FinancialInput.new(ledger_id: ledger, date: date, lines: lines, receipt: form.receipt.presence)
      else
        document_input(form, ledger, date)
      end
    end

    # Facture d'achat ou de vente : tiers et échéance en plus.
    def document_input(form : EntryForm, ledger : Int64?, date : Time?) : Acc::DocumentInput?
      due = parse_day(form, "due_date", form.due_date, required: false)
      form.due_date_hint = due.try { |day| fmt.date(day) }
      lines = document_lines(form)
      return if form.invalid || ledger.nil? || date.nil?
      third = card_code?(form.third_party) || form.third_party
      Acc::DocumentInput.new(ledger_id: ledger, date: date, third_party: third, lines: lines, label: form.label,
        receipt: form.receipt.presence, due_date: due)
    end

    def add_errors(form : EntryForm, errors : Array(Partiduo::Api::FieldError)) : Nil
      errors.each { |error| form.add_error(error.field, fmt.message(error)) }
    end
  end

  # Écran de saisie : formulaire, ajout et retrait de lignes sans
  # JavaScript, enregistrement.
  class EntryHandler < EntryScreen
    def get
      require!("ACCOUNTING", PERMISSION)
      show(blank_form)
    end

    def post
      require!("ACCOUNTING", PERMISSION)
      form = EntryForm.read(entry_kind, form_values)
      if field("add_line") == "1"
        form.add_line
        return show(form)
      end
      if index = field("remove_line").to_i?
        form.remove_line(index)
        return show(form.renumber!)
      end
      input = entry_input(form)
      return show(form, 422) unless input
      result = post_entry(input)
      if result.success?
        flash["success"] = I18n.t("ui.entries.saved", count: result.receipts.size, receipts: result.receipts.join(", "))
        return go("#{request.path}?#{URI::Params.encode({"ledger" => form.ledger_id, "date" => form.date})}")
      end
      add_errors(form, result.errors)
      show(form, 422)
    end

    record Outcome, receipts : Array(String), errors : Array(Partiduo::Api::FieldError) do
      def success? : Bool
        errors.empty?
      end
    end

    private def post_entry(input) : Outcome
      actor = current.actor
      case input
      when Acc::EntryInput
        result = Acc.post_entry(actor, input)
        Outcome.new(result.value?.try { |entry| [entry.receipt || entry.internal_code] } || [] of String, result.errors)
      when Acc::FinancialInput
        result = Acc.post_financial(actor, input)
        Outcome.new(result.value?.try(&.map { |entry| entry.receipt || entry.internal_code }) || [] of String, result.errors)
      when Acc::DocumentInput
        result = entry_kind == "sale" ? Acc.post_sale(actor, input) : Acc.post_purchase(actor, input)
        Outcome.new(result.value?.try { |entry| [entry.receipt || entry.internal_code] } || [] of String, result.errors)
      else
        Outcome.new([] of String, [] of Partiduo::Api::FieldError)
      end
    end
  end

  class PurchaseEntryHandler < EntryHandler
    def default_kind : String
      "purchase"
    end
  end

  class SaleEntryHandler < EntryHandler
    def default_kind : String
      "sale"
    end
  end

  class FinancialEntryHandler < EntryHandler
    def default_kind : String
      "financial"
    end
  end

  class MiscEntryHandler < EntryHandler
    def default_kind : String
      "misc"
    end
  end

  # Retour instantané (HTMX) : équilibre, totaux, lignes calculées et refus,
  # par la requête de contrôle du contrat. Rien n'est enregistré.
  class EntryCheckHandler < EntryScreen
    def post
      require!("ACCOUNTING", PERMISSION)
      form = EntryForm.read(entry_kind, form_values)
      check = EntryCheck.new(fmt)
      balance(form, check) if entry_kind == "misc"
      if input = entry_input(form)
        draft(input, check, form)
      end
      check.errors = collect_errors(form)
      check.date_hint = form.date_hint
      check.due_date_hint = form.due_date_hint
      render("ui/entries/_check.html", {"check" => check, "kind" => entry_kind})
    end

    # Équilibre seul des lignes lisibles (`check_entry(CheckEntryInput)`),
    # affiché même quand l'en-tête est incomplet. Le contrat refuse une
    # saisie déséquilibrée sans rendre ses totaux : l'interface affiche alors
    # les sommes saisies et l'écart que donne le refus (D-UI-027).
    private def balance(form : EntryForm, check : EntryCheck) : Nil
      probe = EntryForm.read(entry_kind, form_values)
      lines = misc_lines(probe).reject(&.amount.zero?)
      return if lines.empty?
      result = Acc.check_entry(current.actor, Acc::CheckEntryInput.new(lines))
      if view = result.value?
        return check.balance(view.total_debit, view.total_credit)
      end
      debit = lines.select(&.side.debit?).sum(BigDecimal.new(0), &.amount)
      credit = lines.select(&.side.credit?).sum(BigDecimal.new(0), &.amount)
      difference = result.errors.find(&.key.ends_with?(".unbalanced")).try { |error| Format.canonical_decimal(error.params["difference"]? || "") }
      check.balance(debit, credit, difference)
    end

    private def draft(input, check : EntryCheck, form : EntryForm) : Nil
      actor = current.actor
      case input
      when Acc::EntryInput
        result = Acc.check_entry(actor, input)
        result.value?.try { |view| check.draft(view) }
      when Acc::DocumentInput
        result = Acc.check_document(actor, input)
        result.value?.try { |view| check.draft(view, document: true) }
      when Acc::FinancialInput
        result = Acc.check_financial(actor, input)
        result.value?.try { |views| check.drafts(views) }
      else
        return
      end
      add_errors(form, result.errors) unless result.success?
    end

    private def collect_errors(form : EntryForm) : Array(String)?
      messages = [] of String
      {form.base_errors, form.ledger_id_errors, form.date_errors, form.receipt_errors, form.third_party_errors,
       form.due_date_errors, form.label_errors}.each { |list| list.try { |items| messages.concat(items) } }
      form.lines.each_with_index do |line, position|
        line.errors.try(&.each { |message| messages << I18n.t("ui.entries.line_error", line: position + 1, message: message) })
      end
      messages.empty? ? nil : messages
    end
  end

  # Nouvelle ligne de saisie (HTMX, Alt+↓ ou « Ajouter une ligne »).
  class EntryLineHandler < EntryScreen
    def get
      require!("ACCOUNTING", PERMISSION)
      index = query("line_next").to_i? || query("index").to_i? || 0
      form = EntryForm.new(entry_kind, [EntryForm::Line.new(index, entry_kind)])
      decorate(form) if form.document
      render("ui/entries/_new_line.html", {"line" => form.lines.first, "next_index" => index + 1})
    end
  end
end
