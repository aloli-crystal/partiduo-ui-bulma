# SPDX-License-Identifier: AGPL-3.0-or-later
# backtick_javascript: true
#
# Saisie entièrement au clavier (ADR-005 D5, DECISIONS D-UI-027) sur un
# formulaire marqué `data-pd-entry` : Entrée avance d'un champ (et ajoute une
# ligne après le dernier), Alt+↓ ajoute une ligne (bouton `data-pd-add-line`,
# chargé par HTMX) puis y place le curseur, Ctrl+Entrée enregistre, le bouton
# `data-pd-del-line` retire la ligne sur place. Le formulaire reste un
# formulaire ordinaire : sans ce paquet, les mêmes boutons l'envoient au
# serveur, qui ajoute ou retire la ligne.
require "native"
require "partiduo_ui/boot"
require "partiduo_ui/entry/keys"

module PartiduoUi
  module Entry
    class Form
      FIELDS = "input:not([type=hidden]):not([disabled]):not([readonly]):not([tabindex='-1']), " \
               "select:not([disabled]), textarea:not([disabled])"

      def self.mount(root)
        form = new(root)
        form.listen
        form
      end

      def initialize(root)
        @root = root
        @focus_new_line = false
      end

      def listen
        @root.addEventListener("keydown") { |event| on_key(Native(event)) }
        @root.addEventListener("click") { |event| on_click(Native(event)) }
        @root.addEventListener("htmx:afterSettle") do |_event|
          if @focus_new_line
            @focus_new_line = false
            focus_last_line
          end
        end
      end

      def on_key(event)
        target = event.target
        tag = target.tagName.to_s.downcase
        type = target.getAttribute("type").to_s.downcase
        action = Keys.action(event.key.to_s, event.ctrlKey == true, event.metaKey == true, event.altKey == true,
                             event.shiftKey == true, tag, type.empty? ? "text" : type)
        return unless action

        event.preventDefault
        case action
        when :save then save
        when :add_line then add_line
        when :next then next_field(target)
        end
      end

      def on_click(event)
        button = event.target.closest("[data-pd-del-line]")
        return unless button

        event.preventDefault
        row = button.closest("tr")
        rows = @root.querySelectorAll("tr[data-pd-line]")
        if rows.length > 1
          row.remove
        else
          fields = row.querySelectorAll("input")
          fields.length.times { |index| fields.item(index).value = "" }
        end
        changed
      end

      def save
        if `typeof #{@root.to_n}.requestSubmit === "function"`
          @root.requestSubmit
        else
          @root.submit
        end
      end

      def add_line
        button = @root.querySelector("[data-pd-add-line]")
        return unless button

        @focus_new_line = true
        button.click
      end

      def next_field(target)
        fields = @root.querySelectorAll(FIELDS)
        position = nil
        fields.length.times do |index|
          position = index if `#{fields.item(index).to_n} === #{target.to_n}`
        end
        following = position && position + 1 < fields.length ? fields.item(position + 1) : nil
        if following
          following.focus
          following.select if following.tagName.to_s.downcase == "input"
        else
          add_line
        end
      end

      def focus_last_line
        rows = @root.querySelectorAll("tr[data-pd-line]")
        return if rows.length.zero?

        field = rows.item(rows.length - 1).querySelector("input")
        field&.focus
      end

      # Relance le contrôle (HTMX écoute `pd:lines`).
      def changed
        @root.dispatchEvent(`new CustomEvent("pd:lines", {bubbles: true})`)
      end
    end
  end
end
