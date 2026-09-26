# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "yaml"
require "../../scripts/icon_sprite"

private SPDX = "SPDX-License-Identifier: AGPL-3.0-or-later"

private def flatten_keys(node : YAML::Any, prefix : String, keys : Set(String)) : Set(String)
  if hash = node.as_h?
    hash.each { |key, value| flatten_keys(value, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}", keys) }
  else
    keys << prefix
  end
  keys
end

describe "Conventions du dépôt" do
  it "impose l'en-tête SPDX à chaque fichier source" do
    root = PartiduoUi::SpecSupport::ROOT
    patterns = %w[src/**/*.cr config/**/*.cr spec/**/*.cr scripts/**/*.cr opal/**/*.rb]
    files = Dir.glob(patterns.map { |pattern| File.join(root, pattern) }) + %w[manage.cr Gemfile scripts/opal-build].map { |file| File.join(root, file) }
    missing = files.reject { |path| File.read_lines(path).first(2).any?(&.starts_with?("# #{SPDX}")) }
    missing.map { |path| Path[path].relative_to(root).to_s }.should eq([] of String)

    written = Dir.glob(%w[src/ui/templates/**/*.html src/ui/locales/*.yml src/ui/assets/ui/css/app.css src/ui/assets/ui/css/fonts.css].map { |pattern| File.join(root, pattern) })
    written.reject { |path| File.read_lines(path).first.includes?(SPDX) }.should eq([] of String)
  end

  it "fournit les mêmes libellés d'écran en fr, en et nl (ADR-005 D7)" do
    dir = PartiduoUi::SpecSupport.path("src", "ui", "locales")
    keys = Partiduo::LOCALES.to_h do |locale|
      {locale, flatten_keys(YAML.parse(File.read(File.join(dir, "#{locale}.yml")))[locale], "", Set(String).new)}
    end
    keys["en"].should eq(keys["fr"])
    keys["nl"].should eq(keys["fr"])
  end

  it "tient la planche d'icônes à jour (crystal run scripts/icon_sprite.cr)" do
    File.read(IconSprite::TARGET).should eq(IconSprite.build)
  end

  it "n'utilise dans les gabarits que des icônes du jeu unique" do
    names = IconSprite.names
    Dir.glob(PartiduoUi::SpecSupport.path("src", "ui", "templates", "**", "*.html")).each do |template|
      File.read(template).scan(/"ui\/_icon\.html" with name="([^"]+)"/).each do |match|
        names.should contain(match[1])
      end
    end
  end
end
