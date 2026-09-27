# SPDX-License-Identifier: AGPL-3.0-or-later

require "./ext/request"
require "./current"
require "./strict_transport_security"
require "./rate_limit"
require "./navigation"
require "./extensions"
require "./format"
require "./screen"
require "./table"
require "./form"
require "./shell"
require "./passkey_json"
require "./qr_svg"
require "./emails/token_email"
require "./handlers/concerns/handler"
require "./handlers/concerns/login_flow"
require "./handlers/auth/**"
require "./handlers/account/security_handlers"
require "./handlers/account/enrollment_handlers"
require "./handlers/screen_handlers"
require "./handlers/extension_handler"
require "./handlers/reference/reference_handler"
require "./handlers/reference/*"

module PartiduoUi
  VERSION = "0.1.0"

  # Application Marten de l'interface Bulma : ses gabarits (`templates/ui/`),
  # ses fichiers statiques (`assets/ui/`) et ses libellés d'écran (`locales/`).
  class App < Marten::App
    label "ui"

    # Monte les interfaces d'extension déclarées par
    # `PartiduoUi::Extensions.mount` (ADR-003 D3), avant que Marten ne prépare
    # les routes : l'ordre des `require` de la distribution n'importe pas.
    def setup
      Extensions.draw
    end
  end
end
