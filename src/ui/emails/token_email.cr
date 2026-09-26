# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Courriel qui porte un lien à usage unique (remise à zéro du mot de passe,
  # déblocage, invitation). Le cœur fournit le jeton et ne produit aucun texte ;
  # l'interface rédige et envoie (doc/api/auth.adoc du cœur). `kind` :
  # `password_reset`, `unlock`, `invitation`.
  class TokenEmail < Marten::Email
    to @address
    subject I18n.t("ui.emails.#{@kind}.subject")

    def initialize(@address : String, @kind : String, @link : String, @expires_at : Time)
    end

    def text_body : String?
      String.build do |io|
        io << I18n.t("ui.emails.#{@kind}.intro") << "\n\n"
        io << @link << "\n\n"
        io << I18n.t("ui.emails.expires", at: @expires_at.to_s("%Y-%m-%d %H:%M UTC")) << "\n"
        io << I18n.t("ui.emails.ignore") << "\n"
      end
    end
  end
end
