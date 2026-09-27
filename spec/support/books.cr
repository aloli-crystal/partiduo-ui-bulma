# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Dossier comptable de test (lot 2) : instance FR provisionnée, exercice
  # 2026, administrateur connecté, fiches ; écritures passées par le contrat.
  module Books
    alias Acc = Partiduo::Api::Accounting

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.admin(regime : String = "fr") : Browser
      Reference.provision(regime)
      Reference.fiscal_year(2026)
      Accounts.create
      Accounts.signed_in
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    def self.ledger(code : String) : Acc::LedgerView
      Acc.ledger_by_code(system, code)
    end

    def self.card(category : String, name : String, code : String? = nil, email : String = "") : Partiduo::Api::Cards::CardView
      found = Reference.category(category)
      input = Partiduo::Api::Cards::CardInput.new(category_id: found.id, name: name, code: code, email: email)
      Partiduo::Api::Cards.create_card(system, input).value!
    end

    # Facture de vente de `amount` HT (TVA normale) au client `code`.
    def self.sale(code : String, amount : String, day : String = "2026-03-10", due : String? = nil) : Acc::EntryView
      input = Acc::DocumentInput.new(ledger_id: ledger("V01").id, date: date(day), third_party: code,
        lines: [Acc::DocumentLineInput.new(amount: d(amount), account: "706", vat_rate: "NOR")],
        due_date: due.try { |text| date(text) }, label: "Facture #{code}")
      Acc.post_sale(system, input).value!
    end

    # Encaissement de `amount` du client `code` sur la banque.
    def self.receipt(code : String, amount : String, day : String = "2026-03-20") : Array(Acc::EntryView)
      input = Acc::FinancialInput.new(ledger_id: ledger("F01").id, date: date(day),
        lines: [Acc::PaymentLineInput.new(d(amount), card: code, label: "Règlement #{code}")])
      Acc.post_financial(system, input).value!
    end

    # Ligne du tiers `code` dans une écriture.
    def self.line_of(entry : Acc::EntryView, code : String) : Acc::EntryLineView
      entry.lines.find! { |line| line.card_code == code }
    end
  end
end
