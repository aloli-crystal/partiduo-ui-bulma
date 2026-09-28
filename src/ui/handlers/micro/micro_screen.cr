# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des écrans de la micro-entreprise (module `MICRO`, ADR-007 D1 et
  # D3) : livre des recettes, registre des achats, aide URSSAF, 2042-C-PRO,
  # seuils, paramètres. Tout passe par `Partiduo::Api::Micro` ; module
  # inactif : le contrat lève `ModuleDisabled`, l'écran répond 404.
  #
  # Vocabulaire courant (ADR-007 D3) : « encaissé », « dépensé », jamais
  # « débit » ni « crédit ».
  abstract class MicroScreen < ReferenceHandler
    alias Micro = Partiduo::Api::Micro

    MODULE   = Micro::MODULE_CODE
    READ     = Micro::READ
    WRITE    = Micro::WRITE
    SETTINGS = Micro::SETTINGS_WRITE

    def today : Time
      Partiduo::Api::Core.today
    end

    # Année demandée (`?year=`), sinon l'année en cours.
    def year_param : Int32
      requested = query("year").to_i?
      requested && requested >= 2000 && requested <= today.year + 1 ? requested : today.year
    end

    # Montant en euros (`1 234,50 €`) : le module suit le régime français.
    def euros(value : BigDecimal?, decimals : Int32 = 2) : String
      value.nil? ? "" : "#{fmt.amount(value, decimals)} €"
    end

    def category_label(category : String) : String
      I18n.t("micro.categories.#{category}")
    end

    # Onglets d'années : les deux précédentes, l'année en cours.
    def year_tabs(path : String, year : Int32, extra = {} of String => String) : Array(Screen::Tab)
      ((today.year - 2)..today.year).map do |value|
        params = extra.merge({"year" => value.to_s})
        Screen::Tab.new(value.to_s, "#{path}?#{URI::Params.encode(params)}", value == year)
      end
    end

    def micro_crumbs : Array(Screen::Crumb)
      [Screen::Crumb.new(I18n.t("ui.micro.menu.dashboard"), reverse("core:dashboard"))]
    end

    # Texte d'un élément « À traiter » du contrat : dates et montants
    # présentés selon la langue.
    def todo_text(item : Micro::TodoView) : String
      MicroText.todo(item, fmt)
    end
  end

  # Textes du module présentés selon la langue (partagés avec le tableau de
  # bord simplifié).
  module MicroText
    AMOUNT_PARAMS = %w[limit turnover]

    # Prochaine déclaration à faire : en retard, due, sinon la période en
    # cours ; l'année précédente comprise (sa dernière échéance tombe en
    # janvier), jamais avant le début d'activité (à défaut, la première
    # recette) ni, sans l'un ni l'autre, avant l'année en cours.
    def self.upcoming(actor : Partiduo::Api::Actor, today : Time) : Partiduo::Api::Micro::DeclarationView?
      start = Partiduo::Api::Micro.settings(actor).activity_started_on ||
              Partiduo::Api::Micro.receipts(actor, Partiduo::Api::Micro::RegisterQuery.new(limit: 1)).first?.try(&.date) ||
              Time.utc(today.year, 1, 1)
      pending = (Partiduo::Api::Micro.declarations(actor, today.year - 1, today) + Partiduo::Api::Micro.declarations(actor, today.year, today))
        .reject { |item| item.status == "declared" || item.ends_on < start }
      pending.find(&.status.==("late")) || pending.find(&.status.==("due")) || pending.find(&.status.==("open")) ||
        pending.find(&.status.==("upcoming"))
    end

    # Libellé d'un paramètre daté (`rate.social.bnc`, `threshold.vat.goods`,
    # `alert.ratio`, `box.flat_tax.sale_bic`) dans la langue courante.
    def self.parameter_label(code : String) : String
      parts = code.split('.')
      category = ->(value : String) { I18n.t("micro.categories.#{value}") }
      case parts[0]
      when "rate"
        I18n.t("ui.micro.parameters.labels.rate_#{parts[1]}", category: category.call(parts[2]? || ""))
      when "threshold"
        I18n.t("ui.micro.parameters.labels.threshold_#{parts[1]}", area: I18n.t("micro.scopes.#{parts[2]? || ""}"))
      when "box"
        if parts.size == 3
          I18n.t("ui.micro.parameters.labels.box_flat_tax", category: category.call(parts[2]))
        else
          I18n.t("ui.micro.parameters.labels.box", category: category.call(parts[1]? || ""))
        end
      else
        I18n.t("ui.micro.parameters.labels.alert_ratio")
      end
    end

    def self.todo(item : Partiduo::Api::Micro::TodoView, fmt : Format) : String
      message(item.key, item.params, fmt)
    end

    def self.message(key : String, params : Hash(String, String), fmt : Format) : String
      shown = params.map do |name, value|
        text = if value.matches?(Format::ISO_DATE)
                 fmt.parse_date(value).try { |day| fmt.date(day) } || value
               elsif AMOUNT_PARAMS.includes?(name)
                 Format.canonical_decimal(value).try { |amount| fmt.amount(amount, 0) } || value
               elsif name == "ratio"
                 Format.canonical_decimal(value).try { |ratio| fmt.number(ratio, 1) } || value
               else
                 value
               end
        {name, text}
      end.to_h
      I18n.t(key, shown)
    end
  end
end
