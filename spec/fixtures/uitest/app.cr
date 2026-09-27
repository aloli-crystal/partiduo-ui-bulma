# SPDX-License-Identifier: AGPL-3.0-or-later

# Extension factice « UITEST », telle que la livrerait un dépôt
# `partiduo-<nom>` : manifeste (métier) et dossier `ui/bulma` (routes montées
# par l'interface sous /ext/UITEST/). Une extension a le droit de déclarer son
# manifeste par `Partiduo::Modules.register` : ce dossier représente un autre
# dépôt et le garde-fou de l'interface l'ignore (DECISIONS D-UI-008).
Partiduo::Modules.register do
  code "UITEST"
  version "0.1.0"
  permission "uitest.page.view"
  permission "uitest.page.edit"
  menu "UITEST_HOME", parent: "EXTENSION", order: 100, route: "uitest:index", permission: "uitest.page.view"
  ui "bulma", path: "ui/bulma"
end

module UiTest
  # Application Marten de l'extension : ses libellés (`locales/`).
  class App < Marten::App
    label "uitest"
  end

  class PageHandler < Marten::Handlers::Base
    def get
      respond("page UITEST #{request.path}")
    end
  end

  ROUTES = Marten::Routing::Map.draw do
    # Permission prise dans le menu du manifeste (uitest.page.view).
    path "/", PageHandler, name: "index"
    # Permission donnée au montage.
    path "/edit", PageHandler, name: "edit"
    # Ni au montage ni au menu : jamais ouverte.
    path "/hidden", PageHandler, name: "hidden"
    # Permission que le manifeste ne déclare pas : jamais ouverte.
    path "/undeclared", PageHandler, name: "undeclared"
    # Chemin vide (/ext/UITEST, sans barre finale) : passe lui aussi par le
    # contrôle d'accès ; ni au montage ni au menu, donc jamais ouvert.
    path "", PageHandler, name: "bare"
  end
end

PartiduoUi::Extensions.mount "UITEST", UiTest::ROUTES,
  permissions: {"edit" => "uitest.page.edit", "undeclared" => "core.settings.manage"}

Marten.configure :test do |config|
  config.installed_apps = config.installed_apps + [UiTest::App] of Marten::Apps::Config.class
end
