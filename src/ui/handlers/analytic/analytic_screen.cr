# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des écrans du module Analytique (lot 5, `Partiduo::Api::Analytic`) :
  # plans et postes, clés de répartition, opérations diverses, ventilation
  # d'une écriture, paramètres, éditions. Module inactif : le contrat lève
  # `ModuleDisabled`, l'écran répond 404 (D-UI-019).
  #
  # Lignes de répartition (clés, opérations diverses, ventilations) :
  # champs `<préfixe>-<n>-<champ>` et un choix de poste par plan
  # (`<préfixe>-<n>-p<plan>`), comme les colonnes `hplan` de NOALYSS
  # (`Anc_Operation::display_form_plan`), rendus par le formulaire générique
  # (un groupe par ligne, DECISIONS D-UI-041).
  abstract class AnalyticScreen < ReferenceHandler
    alias Ana = Partiduo::Api::Analytic

    MODULE = "ANALYTIC"

    # Lignes vides proposées après les lignes remplies.
    SPARE_ROWS = 2

    @plans : Array(Ana::PlanView)?
    @posts_by_plan : Hash(Int64, Array(Ana::PostView))?

    def analytic_crumbs(label_key : String? = nil, url : String? = nil) : Array(Screen::Crumb)
      crumbs = [crumb("core.menu.analytic")]
      crumbs << crumb(label_key, url) if label_key
      crumbs
    end

    # Plans, par nom (colonnes des lignes de répartition).
    def plans : Array(Ana::PlanView)
      @plans ||= Ana.plans(current.actor)
    end

    # Postes de chaque plan (tous, actifs ou non : un poste inactif déjà
    # imputé reste affiché, le contrat refuse d'en imputer un nouveau).
    def posts_by_plan : Hash(Int64, Array(Ana::PostView))
      @posts_by_plan ||= Ana.posts(current.actor).group_by(&.plan_id)
    end

    def post_label(post : Ana::PostView | Ana::PostRef) : String
      post.description.empty? ? post.code : "#{post.code} · #{post.description}"
    end

    # Choix d'un poste du plan : postes actifs, et le poste déjà choisi.
    def post_options(plan_id : Int64, selected : String) : Array(Form::Option)
      posts = (posts_by_plan[plan_id]? || [] of Ana::PostView).select { |post| post.active || post.id.to_s == selected }
      [option("", I18n.t("ui.analytic.no_post"))] + posts.map { |post| option(post.id.to_s, post_label(post)) }
    end

    # Champ de poste d'un plan pour la ligne `prefix` (`rows-0`).
    def post_field(prefix : String, plan : Ana::PlanView, selected : String) : Form::Field
      Form::Field.new("#{prefix}-p#{plan.id}", plan.name, "select", selected, options: post_options(plan.id, selected))
    end

    # Postes choisis sur la ligne `prefix`, un par plan au plus.
    def read_post_ids(prefix : String) : Array(Int64)
      plans.compact_map { |plan| field("#{prefix}-p#{plan.id}").to_i64? }
    end

    # Postes d'une ligne déjà enregistrée, par plan (`plan_id → post_id`).
    def selected_posts(posts : Array(Ana::PostRef)) : Hash(Int64, String)
      posts.to_h { |post| {post.plan_id, post.id.to_s} }
    end

    # Indices des lignes envoyées (`rows-3-amount` → 3), dans l'ordre.
    def row_indices(prefix : String) : Array(Int32)
      pattern = /\A#{Regex.escape(prefix)}-(\d+)-/
      request.data.compact_map { |(name, _)| name.match(pattern).try(&.[1].to_i) }.uniq!.sort!
    end

    # Chemin d'erreur du contrat → champ du formulaire :
    # `rows[2].percent` → `rows-2-percent`, `rows[2].post_ids` → premier
    # poste de la ligne ; `lines[0].rows[1].amount` → `lines-0-rows-1-amount`.
    def error_field(path : String) : String
      name = path.gsub(/\[(\d+)\]\.?/) { "-#{$1}-" }.rchop('-')
      if name.ends_with?("-post_ids")
        first = plans.first?
        name = first ? name.sub(/-post_ids\z/, "-p#{first.id}") : name
      end
      name
    end

    def add_contract_errors(form : Form, errors : Array(Partiduo::Api::FieldError)) : Form
      errors.each { |error| form.add_error(error_field(error.field), fmt.message(error)) }
      form
    end

    # Montant saisi (format de la langue) ; `nil` et erreur si illisible.
    def amount_of(name : String, errors : Array({String, String}), required : Bool = true) : BigDecimal?
      decimal(name, errors, required)
    end

    def amount_text(value : BigDecimal) : String
      fmt.amount(value, group: false)
    end

    def no_plan? : Bool
      plans.empty?
    end

    # Libellé du sens d'une opération.
    def side_label(side : Partiduo::Api::Accounting::Side?) : String
      return "" unless side
      I18n.t(side.debit? ? "ui.analytic.debit" : "ui.analytic.credit")
    end

    def plan_url(id : Int64) : String
      reverse("analytic:plan", id: id)
    end

    def post_url(id : Int64) : String
      reverse("analytic:post", id: id)
    end

    def entry_url(id : Int64?) : String?
      id.try { |value| reverse("accounting:entry", id: value) }
    end

    def iso(day : Time?) : String?
      day.try(&.to_s("%Y-%m-%d"))
    end
  end
end
