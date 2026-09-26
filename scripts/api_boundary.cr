# SPDX-License-Identifier: AGPL-3.0-or-later

# Garde-fou de l'ADR-005 D3, second point : partiduo-ui-bulma ne référence,
# dans partiduo-app, que le contrat `Partiduo::Api`. Utilisé par la spec
# `spec/architecture/api_boundary_spec.cr` et, en CI, directement :
#
#   crystal run scripts/api_boundary.cr -- src config spec manage.cr
#
# Seules exceptions : la *composition* de la distribution, qui n'expose aucune
# règle métier (DECISIONS, décision sur le garde-fou de l'interface).
module ApiBoundary
  record Violation, path : String, line : Int32, reason : String do
    def to_s(io : IO) : Nil
      io << path << ':' << line << " — " << reason
    end
  end

  # Constantes de premier niveau de `Partiduo` admises hors de `Api` :
  # applications à installer, langues livrées, versions.
  ALLOWED_CONSTANTS = %w[Api INSTALLED_APPS LOCALES VERSION API_VERSION]

  # Méthodes de module `Partiduo.xxx` admises : réglages Marten communs.
  ALLOWED_METHODS = %w[apply_settings]

  # `require` admis vers le shard du cœur : le point d'entrée et la ligne de
  # commande (migrations).
  ALLOWED_REQUIRES = %w[partiduo partiduo/cli]

  CONSTANT_PATTERN = /(?<![\w:])(?:::)?Partiduo::([A-Za-z_]\w*)/
  METHOD_PATTERN   = /(?<![\w:])(?:::)?Partiduo\.([a-z_]\w*[?!]?)/
  REQUIRE_PATTERN  = /\brequire\s+"(partiduo(?:\/[^"]*)?)"/
  REOPEN_PATTERN   = /^\s*(?:module|class|struct|include|extend)\s+(?:::)?Partiduo\b/

  def self.scan(paths : Enumerable(String), base : String? = nil) : Array(Violation)
    violations = [] of Violation
    files(paths).each do |path|
      shown = base ? Path[path].relative_to(base).to_s : path
      File.read_lines(path).each_with_index(1) do |text, number|
        code = strip_comment(text)
        next if code.blank?

        check_line(code) { |reason| violations << Violation.new(shown, number, reason) }
      end
    end
    violations
  end

  def self.check_line(code : String, & : String ->) : Nil
    code.scan(CONSTANT_PATTERN) do |match|
      yield "référence interne au cœur : Partiduo::#{match[1]}" unless ALLOWED_CONSTANTS.includes?(match[1])
    end
    code.scan(METHOD_PATTERN) do |match|
      yield "appel interne au cœur : Partiduo.#{match[1]}" unless ALLOWED_METHODS.includes?(match[1])
    end
    code.scan(REQUIRE_PATTERN) do |match|
      yield %(require interne au cœur : "#{match[1]}") unless ALLOWED_REQUIRES.includes?(match[1])
    end
    yield "réouverture ou inclusion d'un espace du cœur" if code.matches?(REOPEN_PATTERN)
  end

  # Fichiers Crystal sous les chemins donnés (répertoires parcourus
  # récursivement, `lib/` exclu, ainsi que `spec/fixtures/`, qui simule le
  # dépôt d'une extension : celle-ci déclare son manifeste par
  # `Partiduo::Modules.register`).
  def self.files(paths : Enumerable(String)) : Array(String)
    paths.flat_map do |path|
      if File.directory?(path)
        Dir.glob(File.join(path, "**", "*.cr")).reject { |file| file.includes?("/lib/") || file.matches?(%r{(\A|/)spec/fixtures/}) }
      elsif File.file?(path) && path.ends_with?(".cr")
        [path]
      else
        [] of String
      end
    end.sort!
  end

  # Retire un commentaire de fin de ligne (hors chaîne, approximation suffisante
  # pour du code formaté par `crystal tool format`).
  def self.strip_comment(line : String) : String
    in_string = false
    previous = '\0'
    line.each_char_with_index do |char, index|
      in_string = !in_string if char == '"' && previous != '\\'
      return line[0, index] if char == '#' && !in_string && line[index + 1]? != '{'
      previous = char
    end
    line
  end
end

# Exécution directe : `crystal run scripts/api_boundary.cr -- src config spec manage.cr`.
if PROGRAM_NAME.includes?("api_boundary")
  paths = ARGV.empty? ? %w[src config spec manage.cr] : ARGV
  violations = ApiBoundary.scan(paths)
  if violations.empty?
    puts "Garde-fou ADR-005 D3 : l'interface ne cite que Partiduo::Api."
  else
    STDERR.puts "Garde-fou ADR-005 D3 : #{violations.size} référence(s) hors de Partiduo::Api :"
    violations.each { |violation| STDERR.puts "  #{violation}" }
    exit 1
  end
end
