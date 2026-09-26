# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :development do |config|
  config.debug = true
  config.host = "127.0.0.1"
  config.port = (ENV["PORT"]? || "8000").to_i
  # Instances en <dossier>.partiduo.localhost (ADR-002 D5) : tout sous-domaine
  # de localhost est admis en développement.
  config.allowed_hosts = ["127.0.0.1", "localhost", ".localhost"]
  config.emailing.backend = Marten::Emailing::Backend::Development.new(print_emails: true)
end
