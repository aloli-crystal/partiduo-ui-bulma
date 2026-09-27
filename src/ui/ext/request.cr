# SPDX-License-Identifier: AGPL-3.0-or-later

class Marten::HTTP::Request
  # Utilisateur de la requête, calculé une seule fois par `PartiduoUi::Current.for`.
  property partiduo_current : PartiduoUi::Current? = nil
end

class Marten::HTTP::Request
  # Mode simplifié de la micro-entreprise, calculé une seule fois par
  # `PartiduoUi::SimpleMode.enabled?`.
  property partiduo_simple : Bool? = nil
end
