# SPDX-License-Identifier: AGPL-3.0-or-later

# Serveur HTTP de Partiduo : `crystal run src/server.cr` (ou le binaire
# `partiduo-server` produit par `shards build`).
require "./partiduo_ui"

Marten.start
