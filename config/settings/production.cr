# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :production do |config|
  config.debug = false
  config.host = "0.0.0.0"
  config.port = (ENV["PORT"]? || "8000").to_i
  config.secret_key = ENV.fetch("MARTEN_SECRET_KEY")
  config.allowed_hosts = ENV.fetch("MARTEN_ALLOWED_HOSTS").split(',').map(&.strip).reject(&.empty?)

  config.sessions.cookie_secure = true
  config.sessions.cookie_http_only = true
  config.csrf.cookie_secure = true
  config.csrf.cookie_http_only = true
  config.templates.cached = true

  # Fichiers statiques collectés (`crystal run manage.cr -- collectassets`)
  # puis servis par Marten, compressés.
  config.assets.root = ENV["PARTIDUO_ASSETS_ROOT"]? || "assets"
  config.middleware = [Marten::Middleware::AssetServing] + config.middleware
end
