# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Paquet de la saisie au clavier (`src/ui/assets/ui/js/opal/entry.js`) :
# écrans de saisie d'écritures et lignes des devis et factures.
require "native"
require "partiduo_ui/entry/form"

PartiduoUi::Boot.register("[data-pd-entry]") do |root|
  PartiduoUi::Entry::Form.mount(root)
end
