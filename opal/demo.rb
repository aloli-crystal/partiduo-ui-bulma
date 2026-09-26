# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exemple minimal d'écran Opal (ADR-001 D4, ADR-005 D5) : un compteur de clics.
#
# Chaque fichier à la racine de `opal/` devient un paquet JavaScript autonome,
# `src/ui/assets/ui/js/opal/<nom>.js`, chargé par le seul gabarit qui en a besoin.
# Recompiler : `scripts/opal-build` (voir README).
require "native"
require "partiduo_ui/demo/counter"

PartiduoUi::Boot.register("[data-opal-counter]") do |root|
  PartiduoUi::Demo::Counter.mount(root)
end
