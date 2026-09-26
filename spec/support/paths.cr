# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  module SpecSupport
    ROOT = File.expand_path("../..", __DIR__)

    def self.path(*parts : String) : String
      File.join(ROOT, *parts)
    end

    # Moteur JavaScript autonome de macOS (JavaScriptCore), sans Node : sert à
    # exécuter les paquets Opal dans les specs quand il est présent.
    JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

    def self.javascript_engine : String?
      ENV["PARTIDUO_JS_ENGINE"]?.presence || (File.exists?(JSC) ? JSC : nil)
    end
  end
end
