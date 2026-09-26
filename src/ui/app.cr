# SPDX-License-Identifier: AGPL-3.0-or-later

require "./handlers/**"

module PartiduoUi
  VERSION = "0.1.0"

  # Application Marten de l'interface Bulma : ses gabarits (`templates/ui/`),
  # ses fichiers statiques (`assets/ui/`) et ses libellés d'écran (`locales/`).
  class App < Marten::App
    label "ui"
  end
end
