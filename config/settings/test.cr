# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :test do |config|
  # Base de test propre à chaque agent ou job : DATABASE_URL (le nom doit
  # contenir « test »). Par défaut : postgres:///partiduo_test?host=/tmp.
  config.database do |db|
    db.from_url(ENV["DATABASE_URL"]?.presence || "postgres:///partiduo_test?host=/tmp")
  end
  config.allowed_hosts = ["127.0.0.1", "localhost"]
  config.cache_store = Marten::Cache::Store::Null.new
  config.emailing.backend = Marten::Emailing::Backend::Development.new(collect_emails: true, print_emails: false)
end
