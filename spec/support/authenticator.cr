# SPDX-License-Identifier: AGPL-3.0-or-later

require "openssl"
require "json"
require "jose"
require "webauthn"

module PartiduoUi
  # Authentificateur de plate-forme simulé (ES256, compteur nul comme chez
  # Apple) : répond aux options JSON de l'interface comme le ferait
  # `navigator.credentials`, et produit les champs que poste `passkey.js`.
  class FakeAuthenticator
    ORIGIN = "http://demo.partiduo.localhost:8000"

    FLAG_UP = WebAuthn::AuthenticatorData::FLAG_USER_PRESENT
    FLAG_UV = WebAuthn::AuthenticatorData::FLAG_USER_VERIFIED
    FLAG_AT = WebAuthn::AuthenticatorData::FLAG_ATTESTED_CREDENTIAL_DATA

    getter key = Jose::JWK::ECKey.generate(Jose::JWK::Curve::P256)
    getter credential_id : Bytes = Random::Secure.random_bytes(32)
    @user_handle : String? = nil

    # Réponse à `navigator.credentials.create()` (options JSON de l'interface).
    def register(options_json : String, name : String = "Portable") : Hash(String, String)
      options = JSON.parse(options_json)
      key = options["publicKey"]
      @user_handle = key["user"]["id"].as_s
      auth_data = authenticator_data(key["rp"]["id"].as_s, FLAG_UP | FLAG_UV | FLAG_AT, attested: true)
      attestation = map([
        {text("fmt"), text("none")},
        {text("attStmt"), Bytes[0xa0]},
        {text("authData"), bytes(auth_data)},
      ])
      {
        "challenge_id"       => options["challengeId"].as_s,
        "attestation_object" => b64(attestation),
        "client_data_json"   => b64(client_data("webauthn.create", key["challenge"].as_s)),
        "transports"         => "internal,hybrid",
        "name"               => name,
      }
    end

    # Réponse à `navigator.credentials.get()`.
    def assert(options_json : String) : Hash(String, String)
      options = JSON.parse(options_json)
      key = options["publicKey"]
      auth_data = authenticator_data(key["rpId"].as_s, FLAG_UP | FLAG_UV, attested: false)
      client = client_data("webauthn.get", key["challenge"].as_s)
      signed = join(auth_data, sha256(client))
      signature = Jose::JWS.sign_data(signed, Jose::JWS::Algorithm::ES256, @key)
      {
        "challenge_id"       => options["challengeId"].as_s,
        "credential_id"      => b64(@credential_id),
        "authenticator_data" => b64(auth_data),
        "client_data_json"   => b64(client),
        "signature"          => b64(signature),
        "user_handle"        => @user_handle || "",
      }
    end

    private def authenticator_data(rp_id : String, flags : UInt8, attested : Bool) : Bytes
      io = IO::Memory.new
      io.write(sha256(rp_id.to_slice))
      io.write_byte(flags)
      4.times { io.write_byte(0_u8) }
      if attested
        io.write(Bytes.new(16))
        io.write_byte(((@credential_id.size >> 8) & 0xff).to_u8)
        io.write_byte((@credential_id.size & 0xff).to_u8)
        io.write(@credential_id)
        public = @key.public_key
        io.write(map([
          {int(1), int(2)},
          {int(3), int(-7)},
          {int(-1), int(1)},
          {int(-2), bytes(public.x)},
          {int(-3), bytes(public.y)},
        ]))
      end
      io.to_slice
    end

    private def client_data(type : String, challenge : String) : Bytes
      %({"type":"#{type}","challenge":"#{challenge}","origin":"#{ORIGIN}","crossOrigin":false}).to_slice
    end

    private def head(major : UInt8, n : Int) : Bytes
      io = IO::Memory.new
      value = n.to_u64
      if value < 24
        io.write_byte((major << 5) | value.to_u8)
      elsif value <= UInt8::MAX
        io.write_byte((major << 5) | 24_u8)
        io.write_byte(value.to_u8)
      else
        io.write_byte((major << 5) | 25_u8)
        io.write_byte((value >> 8).to_u8)
        io.write_byte((value & 0xff).to_u8)
      end
      io.to_slice
    end

    private def int(value : Int) : Bytes
      value < 0 ? head(1_u8, -1 - value) : head(0_u8, value)
    end

    private def bytes(value : Bytes) : Bytes
      join(head(2_u8, value.size), value)
    end

    private def text(value : String) : Bytes
      join(head(3_u8, value.bytesize), value.to_slice)
    end

    private def map(pairs : Array(Tuple(Bytes, Bytes))) : Bytes
      io = IO::Memory.new
      io.write(head(5_u8, pairs.size))
      pairs.each do |(key, value)|
        io.write(key)
        io.write(value)
      end
      io.to_slice
    end

    private def join(*parts : Bytes) : Bytes
      io = IO::Memory.new
      parts.each { |part| io.write(part) }
      io.to_slice
    end

    private def sha256(value : Bytes) : Bytes
      OpenSSL::Digest.new("SHA256").update(value).final
    end

    private def b64(value : Bytes) : String
      Base64.urlsafe_encode(value, padding: false)
    end
  end
end
