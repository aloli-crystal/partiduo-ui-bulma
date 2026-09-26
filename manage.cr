# SPDX-License-Identifier: AGPL-3.0-or-later

# Ligne de commande Marten de l'interface : `crystal run manage.cr -- <commande>`
# (`migrate`, `collectassets`, `routes`…).
require "./src/cli"

Marten.setup
Marten::CLI.run
