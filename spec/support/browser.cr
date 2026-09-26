# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Navigateur de test : garde les cookies d'une requête à l'autre (le client
  # de Marten ne conserve que ceux de la dernière réponse), envoie les
  # formulaires encodés comme un navigateur.
  class Browser
    FORM = "application/x-www-form-urlencoded"

    getter jar = {} of String => String
    getter headers = {} of String => String

    def initialize(locale : String = "fr")
      @headers["Accept-Language"] = locale
    end

    def get(path : String, headers = {} of String => String) : Marten::HTTP::Response
      perform { |client| client.get(path, headers: @headers.merge(headers)) }
    end

    def post(path : String, data = {} of String => String, headers = {} of String => String) : Marten::HTTP::Response
      perform { |client| client.post(path, data: data, content_type: FORM, headers: @headers.merge(headers)) }
    end

    def htmx_post(path : String, data = {} of String => String) : Marten::HTTP::Response
      post(path, data, {"HX-Request" => "true"})
    end

    # Suit une redirection (une seule).
    def follow(response : Marten::HTTP::Response) : Marten::HTTP::Response
      get(response.headers["Location"])
    end

    def cookie(name : String) : String?
      @jar[name]?
    end

    private def perform(& : Marten::Spec::Client -> Marten::HTTP::Response) : Marten::HTTP::Response
      client = Marten::Spec::Client.new
      @jar.each { |name, value| client.cookies[name] = value }
      response = yield client
      client.cookies.each do |(name, value)|
        value.empty? ? @jar.delete(name) : (@jar[name] = value)
      end
      response
    end
  end
end

class Marten::HTTP::Response
  # Contenu avec les entités HTML décodées (`d&#39;accès` → `d'accès`), pour
  # comparer au texte affiché.
  def html : String
    HTML.unescape(content)
  end
end
