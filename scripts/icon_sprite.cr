# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu d'icônes unique de l'interface (ADR-005 D5) : Lucide (licence ISC), un
# fichier SVG par icône dans `icons/lucide/`, assemblés en une planche de
# symboles `src/ui/assets/ui/icons/sprite.svg`.
#
#   crystal run scripts/icon_sprite.cr            # régénère la planche
#   crystal run scripts/icon_sprite.cr -- --check # échoue si elle est périmée
#
# Ajouter une icône : copier son SVG depuis Lucide (même version, voir
# `icons/lucide/VERSION`) dans `icons/lucide/`, puis régénérer. Dans un
# gabarit : `{% include "ui/_icon.html" with name="search" %}`.
module IconSprite
  ROOT   = File.expand_path("..", __DIR__)
  SOURCE = File.join(ROOT, "icons", "lucide")
  TARGET = File.join(ROOT, "src", "ui", "assets", "ui", "icons", "sprite.svg")

  ATTRIBUTES = %(viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round")

  def self.names(source = SOURCE) : Array(String)
    Dir.glob(File.join(source, "*.svg")).map { |path| File.basename(path, ".svg") }.sort!
  end

  def self.build(source = SOURCE) : String
    String.build do |io|
      io << "<!-- SPDX-License-Identifier: ISC — Lucide (https://lucide.dev), voir icons/lucide/LICENSE.\n"
      io << "     Généré par scripts/icon_sprite.cr — ne pas modifier. -->\n"
      io << %(<svg xmlns="http://www.w3.org/2000/svg" style="display:none">\n)
      names(source).each do |name|
        io << %(<symbol id="#{name}" #{ATTRIBUTES}>)
        io << inner(File.read(File.join(source, "#{name}.svg")))
        io << "</symbol>\n"
      end
      io << "</svg>\n"
    end
  end

  # Contenu entre la balise <svg …> et </svg>, sur une ligne.
  def self.inner(svg : String) : String
    body = svg.sub(/\A.*?<svg\b[^>]*>/m, "").sub(/<\/svg>\s*\z/m, "")
    body.lines.map(&.strip).reject(&.empty?).join
  end
end

if PROGRAM_NAME.includes?("icon_sprite")
  sprite = IconSprite.build
  if ARGV.includes?("--check")
    unless File.exists?(IconSprite::TARGET) && File.read(IconSprite::TARGET) == sprite
      STDERR.puts "Planche d'icônes périmée. Lancez : crystal run scripts/icon_sprite.cr"
      exit 1
    end
    puts "Planche d'icônes à jour (#{IconSprite.names.size} icônes)."
  else
    Dir.mkdir_p(File.dirname(IconSprite::TARGET))
    File.write(IconSprite::TARGET, sprite)
    puts "#{IconSprite.names.size} icônes -> #{IconSprite::TARGET.lchop(IconSprite::ROOT + "/")}"
  end
end
