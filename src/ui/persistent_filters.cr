# SPDX-License-Identifier: AGPL-3.0-or-later

require "uri"

module PartiduoUi
  # Filtres persistants (ADR-005 D5, DECISIONS D-UI-035) : les critères d'un
  # écran de liste ou d'édition sont gardés dans un cookie propre à l'écran
  # (`partiduo_f_<écran>`). Revenir sur l'écran sans critère ramène ceux de
  # la dernière visite, par une redirection : l'adresse affichée porte
  # toujours les critères appliqués (lien partageable, retour arrière
  # fidèle). `?reset=1` oublie les critères et revient aux valeurs par défaut.
  # Le formulaire de filtres envoie `f=1`, gardé avec les critères : des
  # critères vides (case décochée, champ effacé) sont alors un choix, gardé
  # comme tel, et non une absence qui ramènerait les valeurs par défaut.
  #
  # Seuls les noms déclarés par l'écran sont gardés (jamais `format`, `page`
  # ni un paramètre inconnu) ; un cookie trop long n'est pas écrit.
  module PersistentFilters
    PREFIX     = "partiduo_f_"
    MAX_LENGTH = 1_500
    LIFETIME   = 180.days

    # Paramètres gardés d'une requête (noms `names`, valeurs non vides).
    def self.pick(params : Marten::HTTP::Params::Query, names : Enumerable(String)) : Hash(String, String)
      kept = {} of String => String
      names.each do |name|
        value = params.fetch(name, nil).try(&.to_s.strip) || ""
        kept[name] = value unless value.empty?
      end
      kept
    end

    # Critères relus d'un cookie : seulement les noms admis.
    def self.decode(value : String?, names : Enumerable(String)) : Hash(String, String)
      kept = {} of String => String
      return kept if value.nil? || value.empty?
      allowed = names.to_set << "f"
      URI::Params.parse(value).each { |name, text| kept[name] = text if allowed.includes?(name) && !text.empty? }
      kept
    end

    # Applique la règle à la requête : `nil` pour poursuivre l'affichage, ou
    # la redirection vers les critères gardés. `screen` : nom court et stable
    # de l'écran (`trial_balance`).
    def self.apply(request : Marten::HTTP::Request, screen : String, names : Array(String)) : Marten::HTTP::Response?
      cookie = PREFIX + screen
      params = request.query_params
      if params.fetch("reset", nil).try(&.to_s) == "1"
        request.cookies.delete(cookie, same_site: "Lax") if request.cookies[cookie]?
        return Navigation.redirect(request, request.path)
      end
      given = pick(params, names)
      submitted = params.fetch("f", nil).try(&.to_s) == "1"
      if given.empty? && !submitted
        saved = decode(request.cookies[cookie]?, names)
        return if saved.empty? || !request.get?
        extra = pick(params, %w[sort format])
        return Navigation.redirect(request, "#{request.path}?#{URI::Params.encode(saved.merge(extra))}")
      end
      encoded = URI::Params.encode(submitted ? given.merge({"f" => "1"}) : given)
      if encoded.bytesize <= MAX_LENGTH && request.cookies[cookie]? != encoded
        request.cookies.set(cookie, encoded, expires: Time.local + LIFETIME, http_only: true,
          secure: Current.secure_cookies?(request), same_site: "Lax")
      end
      nil
    end
  end
end
