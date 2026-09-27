# SPDX-License-Identifier: AGPL-3.0-or-later

# La limitation par adresse IP est tenue en mémoire : chaque exemple repart
# de zéro.
Spec.before_each { PartiduoUi::RateLimit.reset! }
