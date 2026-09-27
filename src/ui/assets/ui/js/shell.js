/* SPDX-License-Identifier: AGPL-3.0-or-later
   Liaison de la coquille au navigateur (DECISIONS D-UI-005), sans logique
   d'écran : repli du menu latéral (tablette, téléphone), raccourci Ctrl+K
   (⌘K) vers la recherche, impression des codes, confirmation des commandes
   (data-pd-confirm). Aucun envoi de formulaire au changement d'une liste
   (WCAG 3.2.2) : langue, période et catégorie ont leur bouton « Appliquer ».
   La page reste utilisable sans JavaScript. */
(function () {
  "use strict";
  var KEY = "partiduo.menu.collapsed";

  function app() { return document.getElementById("pd-app"); }

  function phone() { return window.matchMedia("(max-width: 767.98px)").matches; }

  function setExpanded(button, expanded) {
    button.setAttribute("aria-expanded", expanded ? "true" : "false");
  }

  function sync() {
    var root = app();
    var button = document.querySelector("[data-pd-menu-toggle]");
    if (!root || !button) return;
    var open = phone() ? root.classList.contains("is-menu-open") : !root.classList.contains("is-menu-collapsed");
    setExpanded(button, open);
  }

  function toggleMenu() {
    var root = app();
    if (!root) return;
    if (phone()) {
      root.classList.toggle("is-menu-open");
    } else {
      var collapsed = root.classList.toggle("is-menu-collapsed");
      try { window.localStorage.setItem(KEY, collapsed ? "1" : "0"); } catch (e) { /* stockage indisponible */ }
    }
    sync();
  }

  document.addEventListener("DOMContentLoaded", function () {
    document.documentElement.classList.add("pd-js");
    var root = app();
    try {
      if (root && window.localStorage.getItem(KEY) === "1") root.classList.add("is-menu-collapsed");
    } catch (e) { /* stockage indisponible */ }
    sync();
    window.matchMedia("(max-width: 767.98px)").addEventListener("change", sync);
  });

  document.addEventListener("click", function (event) {
    var target = event.target;
    if (!(target instanceof Element)) return;
    if (target.closest("[data-pd-menu-toggle]")) { toggleMenu(); return; }
    if (target.closest("[data-pd-print]")) { window.print(); }
  });

  document.addEventListener("submit", function (event) {
    var form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    var message = form.getAttribute("data-pd-confirm");
    if (message && !window.confirm(message)) event.preventDefault();
  }, true);

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      var root = app();
      if (root && root.classList.contains("is-menu-open")) {
        root.classList.remove("is-menu-open");
        sync();
        var button = document.querySelector("[data-pd-menu-toggle]");
        if (button) button.focus();
      }
      return;
    }
    // Raccourci avec modificateur (WCAG 2.1.4) : jamais une touche de
    // caractère seule, qui gênerait la commande vocale et les lecteurs d'écran.
    if (!(event.key === "k" || event.key === "K") || !(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return;
    var search = document.querySelector("[data-pd-search]");
    if (search) { event.preventDefault(); search.focus(); }
  });
})();
