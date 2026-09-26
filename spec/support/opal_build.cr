# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module PartiduoUi
  # Miroir, sans Ruby, du calcul d'empreinte de `scripts/opal-build` : pour
  # chaque fichier .rb de `opal/`, trié par chemin relatif, « chemin\0contenu\0 ».
  module OpalBuild
    SOURCES = SpecSupport.path("opal")
    OUTPUT  = SpecSupport.path("src", "ui", "assets", "ui", "js", "opal")

    def self.sources_digest : String
      digest = Digest::SHA256.new
      Dir.glob(File.join(SOURCES, "**", "*.rb")).map(&.lchop(SOURCES + "/")).sort!.each do |relative|
        digest << relative << "\0" << File.read(File.join(SOURCES, relative)) << "\0"
      end
      digest.hexfinal
    end

    # Paquets attendus : un par fichier à la racine de `opal/`.
    def self.entries : Array(String)
      Dir.glob(File.join(SOURCES, "*.rb")).map { |path| File.basename(path, ".rb") }.sort!
    end

    def self.header(name : String) : String
      File.open(File.join(OUTPUT, "#{name}.js")) { |file| file.read_string(Math.min(600, file.size)) }
    end

    # Version d'Opal verrouillée par Gemfile.lock.
    def self.locked_version : String?
      File.read_lines(SpecSupport.path("Gemfile.lock")).each do |line|
        if match = line.match(/\A    opal \(([^)]+)\)\z/)
          return match[1]
        end
      end
      nil
    end
  end
end
