# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée de l'interface partiduo-ui-bulma (ADR-005) : compose le cœur
# (`partiduo`, contrat Partiduo::Api) et l'application Marten `ui`, qui
# apporte routes, handlers, gabarits et fichiers statiques.
require "partiduo"

require "./ui/app"

require "../config/settings/base"
require "../config/settings/**"
require "../config/routes"
