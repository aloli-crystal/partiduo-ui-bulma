# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # En-tête `Strict-Transport-Security` sur les réponses servies en HTTPS
  # (derrière le proxy qui termine TLS, `use_x_forwarded_proto`) : le
  # navigateur ne tentera plus jamais `http://` sur l'instance, où cookies et
  # jetons pourraient fuir (D-UI-021). Rien en HTTP (développement).
  class StrictTransportSecurity < Marten::Middleware
    MAX_AGE = 63_072_000 # deux ans

    def call(request : Marten::HTTP::Request, get_response : Proc(Marten::HTTP::Response)) : Marten::HTTP::Response
      response = get_response.call
      if request.secure? && !response.headers[:"Strict-Transport-Security"]?
        response.headers[:"Strict-Transport-Security"] = "max-age=#{MAX_AGE}; includeSubDomains"
      end
      response
    end
  end
end
