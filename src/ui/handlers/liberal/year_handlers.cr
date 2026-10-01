# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Clôture et réouverture de l'exercice libéral (DECISIONS D-LIB5-001,
  # D-LIB5-005), depuis le livre-journal, les recettes, les dépenses ou la
  # 2035 : POST seulement (bouton avec confirmation), droit de saisie ;
  # retour à la page d'origine (`next`, chemin du site), sinon à la 2035 de
  # l'année ; refus du contrat dans un message (exercice verrouillé, clos au
  # socle, déjà clôturé…).
  abstract class LiberalYearHandler < LiberalScreen
    abstract def change(year : Int32) : Partiduo::Api::Result(Liberal::YearView)
    abstract def done_key : String

    def post
      require!(MODULE, WRITE)
      year = params["year"].to_s.to_i
      result = change(year)
      if result.success?
        flash["success"] = I18n.t(done_key, year: year.to_s)
      else
        flash["danger"] = messages(result.errors)
      end
      go(Navigation.next_path(request, "#{reverse("liberal:tax_return")}?year=#{year}"))
    end
  end

  class LiberalYearCloseHandler < LiberalYearHandler
    def change(year : Int32) : Partiduo::Api::Result(Liberal::YearView)
      Liberal.close_year(current.actor, year)
    end

    def done_key : String
      "ui.liberal.exercise.closed_done"
    end
  end

  class LiberalYearReopenHandler < LiberalYearHandler
    def change(year : Int32) : Partiduo::Api::Result(Liberal::YearView)
      Liberal.reopen_year(current.actor, year)
    end

    def done_key : String
      "ui.liberal.exercise.reopened_done"
    end
  end
end
