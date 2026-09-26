# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Seule dépendance Ruby du dépôt : le compilateur Opal (ADR-005 D5), utilisé
# par scripts/opal-build. Aucune dépendance npm ni Node.
source "https://rubygems.org"

gem "opal", "1.8.2"
# Opal 1.8 charge base64, retiré des gems par défaut depuis Ruby 3.4.
gem "base64", "0.3.0"
