# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Ventilation analytique dans la saisie d'une écriture (lot 5, DECISIONS
  # D-UI-042), successeur des colonnes « hplan » de NOALYSS
  # (`Anc_Operation::display_form_plan`) : sur chaque ligne, un poste par
  # plan et une clé de répartition facultative. Un poste par plan impute tout
  # le montant de la ligne ; une clé le répartit (`Api::Analytic.apply_key`).
  # Une répartition plus fine se fait après l'enregistrement, depuis la
  # consultation de l'écriture (`analytic:entry_distribution`). Aucune règle
  # ici : le contrat contrôle comptes ventilés, montants et mode obligatoire.
  module EntryAnalytic
    alias Ana = Partiduo::Api::Analytic

    class Plan
      include Marten::Template::Object::Auto

      getter id : Int64
      getter name : String

      def initialize(@id, @name)
      end
    end

    class Select
      include Marten::Template::Object::Auto

      getter name : String
      getter label : String
      getter aria : String
      getter options : Array(Form::Option)

      def initialize(@name, @label, @aria, @options)
      end
    end

    # Choix affichés d'une ligne.
    class Cell
      include Marten::Template::Object::Auto

      getter selects : Array(Select)
      getter key : Select?

      def initialize(@selects, @key)
      end
    end

    # Données communes à toutes les lignes d'un formulaire.
    record Choices, plans : Array(Ana::PlanView), posts : Hash(Int64, Array(Ana::PostView)), keys : Array(Ana::KeyView)

    def self.choices(actor : Partiduo::Api::Actor) : Choices?
      plans = Ana.plans(actor)
      return if plans.empty?
      Choices.new(plans, Ana.posts(actor, active_only: true).group_by(&.plan_id), Ana.keys(actor))
    end

    def self.decorate(form : EntryForm, choices : Choices) : Nil
      form.analytic_plans = choices.plans.map { |plan| Plan.new(plan.id, plan.name) }
      form.each_row { |line| line.analytic = cell(line, choices) }
    end

    def self.cell(line : EntryForm::Line, choices : Choices) : Cell
      selects = choices.plans.map do |plan|
        selected = line.ana_posts[plan.id]? || ""
        options = [Form::Option.new("", "—", selected.empty?)] +
                  (choices.posts[plan.id]? || [] of Ana::PostView).map do |post|
                    Form::Option.new(post.id.to_s, post.description.empty? ? post.code : "#{post.code} · #{post.description}", post.id.to_s == selected)
                  end
        Select.new("line-#{line.index}-ana-p#{plan.id}", plan.name,
          I18n.t("ui.analytic.entry.aria_post", plan: plan.name, line: line.number), options)
      end
      key = unless choices.keys.empty?
        options = [Form::Option.new("", I18n.t("ui.analytic.no_key"), line.ana_key.empty?)] +
                  choices.keys.map { |item| Form::Option.new(item.id.to_s, item.name, item.id.to_s == line.ana_key) }
        Select.new("line-#{line.index}-ana_key", I18n.t("ui.analytic.key"),
          I18n.t("ui.analytic.entry.aria_key", line: line.number), options)
      end
      Cell.new(selects, key)
    end

    # Ventilations demandées, désignées par le rang de la ligne dans la
    # saisie (`lines[i]` du contrat = rang dans `filled_lines`) : le cœur
    # retrouve la ligne d'écriture produite et calcule le montant ventilé
    # (clé ou ligne entière). Aucune reconstruction de l'écriture ici
    # (D-UI-042, D-ANA-012). Renvoie aussi la ligne du formulaire de chaque
    # ventilation (erreurs `distributions[i]`).
    def self.distributions(form : EntryForm) : {Array(Ana::InputDistributionInput), Array(EntryForm::Line)}
      inputs = [] of Ana::InputDistributionInput
      owners = [] of EntryForm::Line
      form.filled_lines.each_with_index do |line, index|
        next unless line.ana_given
        inputs << if key_id = line.ana_key.to_i64?
          Ana::InputDistributionInput.new(index, key_id: key_id)
        else
          Ana::InputDistributionInput.new(index, post_ids: line.ana_posts.values.compact_map(&.to_i64?))
        end
        owners << line
      end
      {inputs, owners}
    end

    # Erreur du contrat `distributions[i]…` (ventilation citée) ou
    # `distributions[input=n]` (ligne saisie `n`) : ligne du formulaire
    # concernée, `nil` sinon (ligne calculée : erreur d'ensemble).
    def self.line_for(path : String, form : EntryForm, owners : Array(EntryForm::Line)) : EntryForm::Line?
      if match = path.match(/\Adistributions\[input=(\d+)\]/)
        form.filled_lines[match[1].to_i]?
      elsif match = path.match(/\Adistributions\[(\d+)\]/)
        owners[match[1].to_i]?
      end
    end
  end
end
