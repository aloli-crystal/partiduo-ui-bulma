# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Touches de la saisie au clavier (ADR-005 D5) : règle pure, sans DOM, testée
# sous JavaScriptCore (spec/opal/build_spec.cr).
#
# * Ctrl+Entrée (⌘+Entrée) : enregistrer ;
# * Alt+↓ : ajouter une ligne ;
# * Entrée dans un champ : passer au champ suivant (comme Tab) ; pas dans une
#   zone de texte, un bouton, une case à cocher ;
# * toute autre touche : comportement du navigateur.
module PartiduoUi
  module Entry
    module Keys
      PASS_THROUGH_TAGS = %w[textarea button a]
      PASS_THROUGH_TYPES = %w[submit button reset checkbox radio file]

      def self.action(key, ctrl = false, meta = false, alt = false, shift = false, tag = "input", type = "text")
        return :save if key == "Enter" && (ctrl || meta)
        return :add_line if key == "ArrowDown" && alt && !ctrl && !meta
        return nil unless key == "Enter" && !alt && !shift
        return nil if PASS_THROUGH_TAGS.include?(tag)
        return nil if tag == "input" && PASS_THROUGH_TYPES.include?(type)

        :next
      end
    end
  end
end
