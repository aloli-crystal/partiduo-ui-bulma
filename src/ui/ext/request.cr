# SPDX-License-Identifier: AGPL-3.0-or-later

class Marten::HTTP::Request
  # Utilisateur de la requête, calculé une seule fois par `PartiduoUi::Current.for`.
  property partiduo_current : PartiduoUi::Current? = nil
end
