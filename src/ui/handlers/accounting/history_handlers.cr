# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Historique à comptabiliser (menu `accounting:invoicing_history`,
  # ADR-006 D2, D-INT-003) : factures, avoirs et règlements de la
  # Facturation qui n'ont pas d'écriture — Comptabilité activée après coup,
  # exercice absent, pièce déjà prise… La liste vient d'un essai à blanc du
  # contrat (`invoicing_history`) ; on comptabilise tout ou un événement, on
  # écarte un événement ou on le rend à la liste (D-2F-010).
  abstract class InvoicingHistoryScreen < AccountingScreen
    PERMISSION = "accounting.entry.post"

    def history_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.entry")]
    end

    def history_url : String
      reverse("accounting:invoicing_history")
    end

    def event_label(name : String) : String
      I18n.t("ui.history.events.#{name.tr(".", "_")}")
    end
  end

  class InvoicingHistoryHandler < InvoicingHistoryScreen
    def get
      require!("ACCOUNTING", PERMISSION)
      pending = Acc.invoicing_history(current.actor)
      dismissed = Acc.dismissed_invoicing_events(current.actor)
      columns = [
        Table::Column.new("date", I18n.t("ui.entries.date"), "mono"),
        Table::Column.new("event", I18n.t("ui.history.event")),
        Table::Column.new("number", I18n.t("ui.invoicing.number"), "mono"),
        Table::Column.new("customer", I18n.t("ui.invoicing.customer"), secondary: true),
        Table::Column.new("amount", I18n.t("ui.entries.amount"), "amount"),
        Table::Column.new("state", I18n.t("ui.history.state")),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = pending.map { |event| row(event, false) } + dismissed.map { |event| row(event, true) }
      table = Table.new(I18n.t("accounting.menu.acc_invoicing_history"), columns, rows, history_url,
        empty_message: I18n.t("ui.history.empty"))
      actions = [] of Screen::Action
      if pending.any?(&.postable?)
        actions << post_action("ui.history.post_all", reverse("accounting:invoicing_history_post"),
          "ui.history.post_all_confirm", "primary", "check")
      end
      list_page(I18n.t("accounting.menu.acc_invoicing_history"), table, history_crumbs, "ui.history.csv_name", actions,
        intro: I18n.t("ui.history.intro"), filter: false)
    end

    private def row(event : Acc::BillingEventView, dismissed : Bool) : Table::Row
      state = if dismissed
                I18n.t("ui.history.dismissed")
              elsif event.postable?
                I18n.t("ui.history.ready")
              else
                event.errors.map { |error| fmt.message(error) }.join(" ")
              end
      actions = if dismissed
                  [post_action("ui.history.restore", reverse("accounting:invoicing_history_restore", id: event.event_id), style: "small")]
                else
                  list = [] of Screen::Action
                  if event.postable?
                    list << post_action("ui.history.post_one", "#{reverse("accounting:invoicing_history_post")}?event=#{event.event_id}",
                      style: "small")
                  end
                  list << post_action("ui.history.dismiss", reverse("accounting:invoicing_history_dismiss", id: event.event_id),
                    "ui.history.dismiss_confirm", "small")
                  list
                end
      Table::Row.new([
        Table::Cell.new(fmt.date(event.date), sort: date_key(event.date), csv: date_key(event.date)),
        Table::Cell.new(event_label(event.event)),
        Table::Cell.new(event.number),
        Table::Cell.new(customer_name(event.customer_card_id)),
        Table::Cell.new(fmt.amount(event.amount), sort: event.amount, csv: fmt.csv_amount(event.amount)),
        Table::Cell.new(state),
        Table::Cell.new("", actions: actions),
      ], dismissed ? "pd-row-closed" : (event.postable? ? "" : "pd-row-late"))
    end

    private def customer_name(id : Int64?) : String
      return "" unless id
      @names[id] ||= begin
        Partiduo::Api::Cards.card(current.actor, id).name
      rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
        ""
      end
    end

    @names = {} of Int64 => String
  end

  # Comptabilise tout l'historique, ou l'événement `?event=<id>`.
  class InvoicingHistoryPostHandler < InvoicingHistoryScreen
    def post
      ids = query("event").to_i64?.try { |id| [id] }
      result = Acc.post_invoicing_history(current.actor, ids)
      if history = result.value?
        flash["success"] = I18n.t("ui.history.posted", count: history.posted.size)
        flash["warning"] = I18n.t("ui.history.remaining", count: history.remaining.size) unless history.remaining.empty?
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(history_url)
    end
  end

  class InvoicingHistoryDismissHandler < InvoicingHistoryScreen
    def post
      result = Acc.dismiss_invoicing_event(current.actor, id_param, field("reason"))
      if result.success?
        flash["success"] = I18n.t("ui.history.dismissed_done")
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(history_url)
    end
  end

  class InvoicingHistoryRestoreHandler < InvoicingHistoryScreen
    def post
      result = Acc.restore_invoicing_event(current.actor, id_param)
      if result.success?
        flash["success"] = I18n.t("ui.history.restored")
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(history_url)
    end
  end
end
