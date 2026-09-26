# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../scripts/api_boundary"

describe "Garde-fou ADR-005 D3 : l'interface ne cite que Partiduo::Api" do
  it "ne trouve aucune référence au cœur hors du contrat" do
    root = PartiduoUi::SpecSupport::ROOT
    paths = %w[src config spec scripts manage.cr].map { |path| File.join(root, path) }
    ApiBoundary.scan(paths, base: root).map(&.to_s).should eq([] of String)
  end

  it "détecte une référence interne glissée dans l'interface" do
    core = "Partiduo"
    dir = File.join(Dir.tempdir, "partiduo-ui-garde-fou-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "fuite.cr"), <<-CR)
      require "#{core.downcase}/accounting/models/entry"
      class Fuite
        def call
          #{core}::Accounting::Entry.all
          #{core}::Config.domain
          ::#{core}::Modules.manifests
          #{core}.internal_helper
          #{core}::Api::Accounting.check_entry(actor, input) # admis
          #{core}::INSTALLED_APPS                           # admis
        end
      end
      module #{core}::Api::Accounting
      end
      CR

    reasons = ApiBoundary.scan([dir]).map(&.reason)
    reasons.should eq([
      %(require interne au cœur : "partiduo/accounting/models/entry"),
      "référence interne au cœur : #{core}::Accounting",
      "référence interne au cœur : #{core}::Config",
      "référence interne au cœur : #{core}::Modules",
      "appel interne au cœur : #{core}.internal_helper",
      "réouverture ou inclusion d'un espace du cœur",
    ])
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "ignore les commentaires" do
    ApiBoundary.strip_comment(%(x = 1 # voir Partiduo::Accounting)).should eq("x = 1 ")
    ApiBoundary.strip_comment(%(s = "a # b")).should eq(%(s = "a # b"))
  end
end
