# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Intégration d'Opal (ADR-001 D4, ADR-005 D5)" do
  it "versionne un paquet JavaScript par écran Opal" do
    PartiduoUi::OpalBuild.entries.should contain("demo")
    PartiduoUi::OpalBuild.entries.each do |name|
      File.exists?(File.join(PartiduoUi::OpalBuild::OUTPUT, "#{name}.js")).should be_true
    end
    Dir.glob(File.join(PartiduoUi::OpalBuild::OUTPUT, "*.js")).map { |path| File.basename(path, ".js") }.sort!
      .should eq(PartiduoUi::OpalBuild.entries)
  end

  it "a recompilé les paquets après la dernière modification des sources (bundle exec scripts/opal-build)" do
    digest = PartiduoUi::OpalBuild.sources_digest
    PartiduoUi::OpalBuild.entries.each do |name|
      PartiduoUi::OpalBuild.header(name).should contain("sources-sha256: #{digest}")
    end
  end

  it "compile avec la version d'Opal verrouillée par Gemfile.lock" do
    version = PartiduoUi::OpalBuild.locked_version
    version.should_not be_nil
    PartiduoUi::OpalBuild.entries.each do |name|
      PartiduoUi::OpalBuild.header(name).should contain("opal-version: #{version}")
    end
  end

  it "embarque le runtime Opal et le composant compilé" do
    javascript = File.read(File.join(PartiduoUi::OpalBuild::OUTPUT, "demo.js"))
    javascript.should contain("var Opal = global_object.Opal = {};")
    javascript.should contain("Opal.modules[\"partiduo_ui/demo/counter\"]")
    javascript.should contain("Opal.modules[\"partiduo_ui/boot\"]")
  end

  it "monte le compteur sur la page et réagit aux clics (DOM simulé)" do
    engine = PartiduoUi::SpecSupport.javascript_engine
    pending!("aucun moteur JavaScript autonome (JavaScriptCore) ; PARTIDUO_JS_ENGINE pour en indiquer un") unless engine

    # DOM minimal, défini avant le chargement du paquet : le compteur se monte
    # sur l'élément [data-opal-counter] dès que le document est prêt.
    dom = File.tempname("partiduo-dom", ".js")
    File.write(dom, <<-JS)
      function El(attrs) { this.attrs = attrs || {}; this.listeners = {}; this.children = {}; this.textContent = ""; }
      El.prototype.getAttribute = function (n) { return n in this.attrs ? this.attrs[n] : null; };
      El.prototype.setAttribute = function (n, v) { this.attrs[n] = String(v); };
      El.prototype.hasAttribute = function (n) { return n in this.attrs; };
      El.prototype.addEventListener = function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); };
      El.prototype.querySelector = function (s) { return this.children[s] || null; };
      El.prototype.dispatch = function (t, e) { (this.listeners[t] || []).forEach(function (f) { f(e || {}); }); };
      var output = new El(), plus = new El(), reset = new El();
      var root = new El({"data-opal-counter": "", "data-value": "5"});
      root.children["[data-opal-counter-output]"] = output;
      root.children["[data-opal-counter-increment]"] = plus;
      root.children["[data-opal-counter-reset]"] = reset;
      var document = new El();
      document.readyState = "complete";
      document.querySelectorAll = function (s) {
        var found = s === "[data-opal-counter]" ? [root] : [];
        return { length: found.length, item: function (i) { return found[i]; } };
      };
      JS

    probe = File.tempname("partiduo-opal", ".js")
    File.write(probe, <<-JS)
      print("monte=" + root.hasAttribute("data-opal-mounted") + " affiche=" + output.textContent);
      plus.dispatch("click"); plus.dispatch("click");
      print("apres2clics=" + output.textContent);
      reset.dispatch("click");
      print("apresremise=" + output.textContent);
      document.dispatch("htmx:load", { target: document });
      print("ecouteurs=" + plus.listeners.click.length);
      JS

    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(engine, [dom, File.join(PartiduoUi::OpalBuild::OUTPUT, "demo.js"), probe], output: output, error: error)
    status.success?.should be_true, "#{error}#{output}"
    output.to_s.lines.should eq(["monte=true affiche=5", "apres2clics=7", "apresremise=0", "ecouteurs=1"])
  ensure
    File.delete?(dom) if dom
    File.delete?(probe) if probe
  end

  it "exécute le paquet compilé : le compteur Ruby fonctionne en JavaScript" do
    engine = PartiduoUi::SpecSupport.javascript_engine
    pending!("aucun moteur JavaScript autonome (JavaScriptCore) ; PARTIDUO_JS_ENGINE pour en indiquer un") unless engine

    probe = File.tempname("partiduo-opal", ".js")
    File.write(probe, <<-JS)
      var Counter = Opal.PartiduoUi.Demo.Counter;
      var counter = Counter.$new(2);
      counter.$increment(); counter.$increment();
      print("valeur=" + counter.$value());
      print("remise=" + counter.$reset().$value());
      print("navigateur=" + Opal.PartiduoUi.Boot["$browser?"]());
      JS

    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(engine, [File.join(PartiduoUi::OpalBuild::OUTPUT, "demo.js"), probe], output: output, error: error)
    status.success?.should be_true, "#{error}#{output}"
    output.to_s.lines.should eq(["valeur=4", "remise=0", "navigateur=false"])
  ensure
    File.delete?(probe) if probe
  end
end
