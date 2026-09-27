# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :production do |config|
  config.debug = false
  config.host = "0.0.0.0"
  config.port = (ENV["PORT"]? || "8000").to_i
  config.secret_key = ENV.fetch("MARTEN_SECRET_KEY")
  config.allowed_hosts = ENV.fetch("MARTEN_ALLOWED_HOSTS").split(',').map(&.strip).reject(&.empty?)

  # TLS est terminé par le proxy (nginx, `deploy/templates/nginx-vhost.conf.tmpl`
  # du cœur), qui doit être de confiance et poser `X-Forwarded-Proto` :
  # `request.secure?` en dépend (cookies `Secure`, HSTS, D-UI-021).
  config.use_x_forwarded_proto = true

  config.sessions.cookie_secure = true
  config.sessions.cookie_http_only = true
  config.csrf.cookie_secure = true
  config.csrf.cookie_http_only = true
  config.templates.cached = true

  # Fichiers statiques collectés (`crystal run manage.cr -- collectassets`)
  # puis servis par Marten, compressés.
  config.assets.root = ENV["PARTIDUO_ASSETS_ROOT"]? || "assets"
  config.middleware = [PartiduoUi::StrictTransportSecurity, Marten::Middleware::AssetServing] + config.middleware
end
