# SPDX-License-Identifier: AGPL-3.0-or-later
# backtick_javascript: true
#
# Amorçage commun des écrans Opal : chaque composant déclare un sélecteur CSS ;
# les éléments correspondants sont montés au chargement de la page et après
# chaque remplacement de contenu par HTMX (événement `htmx:load`). Un élément
# n'est monté qu'une fois (attribut `data-opal-mounted`).
require "native"

module PartiduoUi
  module Boot
    @components = []

    def self.register(selector, &mount)
      @components << [selector, mount]
      start if browser?
    end

    # Vrai dans un navigateur, faux sous un moteur JavaScript nu (specs).
    def self.browser?
      `typeof document !== "undefined"`
    end

    def self.start
      return if @started
      @started = true

      # Nom de variable distinct de `document` : Opal en ferait une variable
      # JavaScript locale qui masquerait l'objet global.
      page = Native(`document`)
      if page.readyState == "loading"
        page.addEventListener("DOMContentLoaded") { |_event| mount_all(page) }
      else
        mount_all(page)
      end
      page.addEventListener("htmx:load") { |event| mount_all(Native(event).target) }
    end

    def self.mount_all(scope)
      @components.each do |selector, mount|
        candidates = []
        candidates << scope if `typeof #{scope.to_n}.matches === "function"` && scope.matches(selector)
        list = scope.querySelectorAll(selector)
        list.length.times { |index| candidates << list.item(index) }

        candidates.each do |element|
          next if element.hasAttribute("data-opal-mounted")

          element.setAttribute("data-opal-mounted", "")
          mount.call(element)
        end
      end
    end
  end
end
