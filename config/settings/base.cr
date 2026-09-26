# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure do |config|
  config.secret_key = ENV["MARTEN_SECRET_KEY"]? || "__insecure_partiduo_ui_bulma_dev_only__"

  # Le cœur d'abord (applications, base, langues, modèle utilisateur), puis
  # l'interface (ADR-005 D1).
  Partiduo.apply_settings(config)
  config.installed_apps = Partiduo::INSTALLED_APPS + [PartiduoUi::App] of Marten::Apps::Config.class

  config.middleware = [
    Marten::Middleware::Session,
    Marten::Middleware::Flash,
    Marten::Middleware::I18n,
    Marten::Middleware::GZip,
    Marten::Middleware::XFrameOptions,
    Marten::Middleware::XContentTypeOptions,
    Marten::Middleware::CrossOriginOpenerPolicy,
    Marten::Middleware::ReferrerPolicy,
  ] of Marten::Middleware.class

  config.templates.context_producers = [
    Marten::Template::ContextProducer::Request,
    Marten::Template::ContextProducer::Flash,
    Marten::Template::ContextProducer::Debug,
    Marten::Template::ContextProducer::I18n,
  ]
end
