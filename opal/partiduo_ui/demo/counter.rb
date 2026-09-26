# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Compteur de clics : l'état vit côté client, les libellés viennent du gabarit
# (attributs `data-*`, déjà traduits par Marten) — aucune chaîne affichée
# n'est écrite ici.
require "partiduo_ui/boot"

module PartiduoUi
  module Demo
    class Counter
      attr_reader :value

      def initialize(value = 0)
        @value = value
      end

      def increment
        @value += 1
        self
      end

      def reset
        @value = 0
        self
      end

      # Montage sur un élément du type :
      #
      #   <div data-opal-counter data-value="0">
      #     <output data-opal-counter-output>0</output>
      #     <button data-opal-counter-increment>…</button>
      #     <button data-opal-counter-reset>…</button>
      #   </div>
      def self.mount(root)
        counter = new(root.getAttribute("data-value").to_i)
        output = root.querySelector("[data-opal-counter-output]")
        render = -> { output.textContent = counter.value.to_s }

        root.querySelector("[data-opal-counter-increment]").addEventListener("click") do |_event|
          counter.increment
          render.call
        end
        root.querySelector("[data-opal-counter-reset]").addEventListener("click") do |_event|
          counter.reset
          render.call
        end

        render.call
        counter
      end
    end
  end
end
