# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.routes.draw do
  path "/", PartiduoUi::HomeHandler, name: "home"

  # Fichiers statiques servis par Marten : directement depuis les applications
  # en développement et en test ; en production, après `collectassets`, par le
  # middleware Marten::Middleware::AssetServing (config/settings/production.cr).
  if Marten.env.development? || Marten.env.test?
    path "#{Marten.settings.assets.url}<path:path>", Marten::Handlers::Defaults::Development::ServeAsset, name: "asset"
  end
end
