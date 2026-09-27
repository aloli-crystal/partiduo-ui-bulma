# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Complétion dès le premier caractère (ADR-005 D5) : options d'une
  # `<datalist>` remplacées par HTMX à chaque frappe. Le texte cherché est le
  # paramètre `q`, à défaut la valeur du champ qui a déclenché la requête
  # (HTMX envoie le champ sous son propre nom). Recherches du contrat
  # seulement (`search_accounts`, `Cards.cards`) ; une recherche que
  # l'acteur n'a pas le droit de faire ne propose rien.
  abstract class CompletionHandler < ScreenHandler
    LIMIT = 12
    META  = %w[list kind]

    def text : String
      value = query("q")
      return value unless value.empty?
      request.query_params.each do |(name, values)|
        next if META.includes?(name)
        found = values.last?.to_s.strip
        return found unless found.empty?
      end
      ""
    end

    def options_response(options : Array(Form::Option)) : Marten::HTTP::Response
      render("ui/_options.html", {"options" => options})
    end

    def accounts(text : String) : Array(Form::Option)
      Partiduo::Api::Accounting.search_accounts(current.actor, text, LIMIT, direct_use_only: true)
        .map { |account| Form::Option.new(account.number, "#{account.number} · #{account.label}") }
    rescue Partiduo::Api::AccessDenied
      [] of Form::Option
    end

    # Fiches de nature `kind` (`nil` : toutes ; `party` : tous les tiers).
    def cards(text : String, kind : String?) : Array(Form::Option)
      wanted = kind == "party" ? nil : kind
      query = Partiduo::Api::Cards::CardQuery.new(search: text, kind: wanted, limit: LIMIT * 2)
      found = Partiduo::Api::Cards.cards(current.actor, query)
      found = found.reject(&.item?) if kind == "party"
      found.first(LIMIT).map { |card| Form::Option.new(card.code, "#{card.code} · #{card.name}") }
    rescue Partiduo::Api::AccessDenied
      [] of Form::Option
    end
  end

  # Fiches du socle (`/cards/complete?kind=customer`) : clients, fournisseurs,
  # articles, tiers.
  class CardCompletionHandler < CompletionHandler
    def get
      search = text
      return options_response([] of Form::Option) if search.empty?
      kind = query("kind").presence
      options_response(cards(search, kind))
    end
  end

  # Comptes et fiches pour la saisie (`/accounting/complete?list=…`) :
  # `accounts` (comptes seuls), `entry` (comptes et tiers), `items` (articles
  # et comptes), `parties` (tiers et comptes).
  class AccountCompletionHandler < CompletionHandler
    def get
      search = text
      return options_response([] of Form::Option) if search.empty?
      options = case query("list")
                when "entry"   then accounts(search) + cards(search, "party")
                when "items"   then cards(search, "item") + accounts(search)
                when "parties" then cards(search, "party") + accounts(search)
                else                accounts(search)
                end
      options_response(options.first(LIMIT * 2))
    end
  end
end
