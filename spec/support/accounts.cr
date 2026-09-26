# SPDX-License-Identifier: AGPL-3.0-or-later

require "totp"

module PartiduoUi
  # Comptes de test, créés par le contrat `Partiduo::Api::Auth` seulement.
  module Accounts
    # Conforme à la politique : 14 caractères et plus, majuscule, minuscule, chiffre.
    PASSWORD = "Correcthorse42battery"

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.profile_id(code : String) : Int64
      Partiduo::Api::Auth.ensure_default_profiles(system).find! { |profile| profile.code == code }.id
    end

    def self.create(email : String = "alice@example.com", password : String? = PASSWORD, profile : String? = "ADMIN",
                    role : String = "member", profile_id : Int64? = nil) : Partiduo::Api::Auth::UserCreatedView
      input = Partiduo::Api::Auth::UserInput.new(
        email: email, first_name: "Alice", last_name: "Martin", role: role,
        profile_id: profile_id || profile.try { |code| profile_id(code) }, password: password,
      )
      Partiduo::Api::Auth.create_user(system, input).value!
    end

    # Profil qui ne porte que les permissions citées.
    def self.profile(name : String, permissions : Array(String)) : Int64
      input = Partiduo::Api::Auth::ProfileInput.new(name: name, permissions: permissions)
      Partiduo::Api::Auth.create_profile(system, input).value!.id
    end

    # Navigateur connecté par mot de passe (utilisateur sans second facteur).
    def self.signed_in(email : String = "alice@example.com", password : String = PASSWORD) : Browser
      browser = Browser.new
      response = browser.post("/login", {"email" => email, "password" => password})
      raise "connexion refusée (#{response.status})" unless response.status == 302
      browser
    end

    def self.token(email : String = "alice@example.com") : String
      input = Partiduo::Api::Auth::PasswordLoginInput.new(email, PASSWORD)
      Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous, input).value!.session_token!
    end

    def self.totp_code(secret : String, time : Time = Time.utc) : String
      TOTP::Authenticator.from_base32(secret).at(time)
    end

    # Active le TOTP par le contrat ; renvoie le secret.
    def self.enable_totp(email : String = "alice@example.com") : String
      actor = Partiduo::Api::Auth.actor(token(email))
      enrollment = Partiduo::Api::Auth.begin_totp_enrollment(actor)
      code = totp_code(enrollment.secret_base32, Time.utc - 30.seconds)
      Partiduo::Api::Auth.confirm_totp_enrollment(actor, code).value!
      enrollment.secret_base32
    end
  end
end
