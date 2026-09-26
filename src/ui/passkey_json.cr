# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoUi
  # Options WebAuthn du contrat mises en forme pour `navigator.credentials`
  # (ADR-002 D2) : `ui/js/passkey.js` convertit en octets les champs en
  # base64url (`challenge`, `user.id`, `id` des credentials).
  module PasskeyJson
    def self.creation(options : Partiduo::Api::Auth::RegistrationOptionsView) : String
      JSON.build do |json|
        json.object do
          json.field "challengeId", options.challenge_id
          json.field "publicKey" do
            json.object do
              json.field "challenge", options.challenge
              json.field "rp" do
                json.object do
                  json.field "id", options.rp_id
                  json.field "name", options.rp_name
                end
              end
              json.field "user" do
                json.object do
                  json.field "id", options.user_handle
                  json.field "name", options.user_name
                  json.field "displayName", options.user_display_name
                end
              end
              json.field "pubKeyCredParams" do
                json.array do
                  options.algorithms.each do |algorithm|
                    json.object do
                      json.field "type", "public-key"
                      json.field "alg", algorithm
                    end
                  end
                end
              end
              json.field "authenticatorSelection" do
                json.object do
                  json.field "residentKey", options.resident_key
                  json.field "requireResidentKey", options.resident_key == "required"
                  json.field "userVerification", options.user_verification
                end
              end
              json.field "attestation", options.attestation
              json.field "timeout", options.timeout_ms
              credentials(json, "excludeCredentials", options.exclude_credentials)
            end
          end
        end
      end
    end

    def self.request(options : Partiduo::Api::Auth::AuthenticationOptionsView) : String
      JSON.build do |json|
        json.object do
          json.field "challengeId", options.challenge_id
          json.field "publicKey" do
            json.object do
              json.field "challenge", options.challenge
              json.field "rpId", options.rp_id
              json.field "userVerification", options.user_verification
              json.field "timeout", options.timeout_ms
              credentials(json, "allowCredentials", options.allow_credentials)
            end
          end
        end
      end
    end

    private def self.credentials(json : JSON::Builder, name : String, ids : Array(String)) : Nil
      json.field name do
        json.array do
          ids.each do |id|
            json.object do
              json.field "type", "public-key"
              json.field "id", id
            end
          end
        end
      end
    end

    # Réponse de `navigator.credentials.get()` transmise par le formulaire.
    def self.assertion(data : Marten::HTTP::Params::Data, context : Partiduo::Api::Auth::LoginContext) : Partiduo::Api::Auth::PasskeyAssertionInput
      Partiduo::Api::Auth::PasskeyAssertionInput.new(
        challenge_id: value(data, "challenge_id"),
        credential_id: value(data, "credential_id"),
        authenticator_data: value(data, "authenticator_data"),
        client_data_json: value(data, "client_data_json"),
        signature: value(data, "signature"),
        user_handle: value(data, "user_handle").presence,
        context: context,
      )
    end

    # Réponse de `navigator.credentials.create()`.
    def self.registration(data : Marten::HTTP::Params::Data) : Partiduo::Api::Auth::PasskeyRegistrationInput
      Partiduo::Api::Auth::PasskeyRegistrationInput.new(
        challenge_id: value(data, "challenge_id"),
        attestation_object: value(data, "attestation_object"),
        client_data_json: value(data, "client_data_json"),
        transports: value(data, "transports").split(',').map(&.strip).reject(&.empty?),
        name: value(data, "name"),
      )
    end

    def self.value(data : Marten::HTTP::Params::Data, name : String) : String
      data.fetch(name, nil).try(&.to_s.strip) || ""
    end

    # Réponse JSON de l'interface à `passkey.js`.
    def self.outcome(ok : Bool, redirect : String? = nil, html : String? = nil, error : String? = nil) : String
      JSON.build do |json|
        json.object do
          json.field "ok", ok
          json.field "redirect", redirect if redirect
          json.field "html", html if html
          json.field "error", error if error
        end
      end
    end
  end
end
