# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Intégration d'Opal (ADR-001 D4, ADR-005 D5)" do
  it "versionne un paquet JavaScript par écran Opal" do
    PartiduoUi::OpalBuild.entries.should contain("demo")
    PartiduoUi::OpalBuild.entries.each do |name|
      File.exists?(File.join(PartiduoUi::OpalBuild::OUTPUT, "#{name}.js")).should be_true
    end
    Dir.glob(File.join(PartiduoUi::OpalBuild::OUTPUT, "*.js")).map { |path| File.basename(path, ".js") }.sort!
      .should eq((PartiduoUi::OpalBuild.entries + ["runtime"]).sort)
  end

  it "a recompilé les paquets après la dernière modification des sources (bundle exec scripts/opal-build)" do
    digest = PartiduoUi::OpalBuild.sources_digest
    (PartiduoUi::OpalBuild.entries + ["runtime"]).each do |name|
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

  it "met le runtime Opal dans un paquet commun, et seulement l'écran dans son paquet (D-UI-023)" do
    runtime = File.read(File.join(PartiduoUi::OpalBuild::OUTPUT, "runtime.js"))
    runtime.should contain("var Opal = global_object.Opal = {};")
    runtime.should contain("Opal.modules[\"partiduo_ui/boot\"]")
    javascript = File.read(File.join(PartiduoUi::OpalBuild::OUTPUT, "demo.js"))
    javascript.should contain("Opal.modules[\"partiduo_ui/demo/counter\"]")
    javascript.should_not contain("var Opal = global_object.Opal = {};")
    javascript.should_not contain("Opal.modules[\"partiduo_ui/boot\"]")
    # Plafonds : un écran ne rembarque jamais le runtime.
    File.size(File.join(PartiduoUi::OpalBuild::OUTPUT, "demo.js")).should be < 50_000
    File.size(File.join(PartiduoUi::OpalBuild::OUTPUT, "runtime.js")).should be < 900_000
  end

  it "charge le paquet commun avant celui de l'écran" do
    template = File.read(PartiduoUi::SpecSupport.path("src", "ui", "templates", "ui", "about.html"))
    template.index!("opal/runtime.js").should be < template.index!("opal/demo.js")
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
    status = Process.run(engine, [dom, File.join(PartiduoUi::OpalBuild::OUTPUT, "runtime.js"),
                                  File.join(PartiduoUi::OpalBuild::OUTPUT, "demo.js"), probe], output: output, error: error)
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
    status = Process.run(engine, [File.join(PartiduoUi::OpalBuild::OUTPUT, "runtime.js"),
                                  File.join(PartiduoUi::OpalBuild::OUTPUT, "demo.js"), probe], output: output, error: error)
    status.success?.should be_true, "#{error}#{output}"
    output.to_s.lines.should eq(["valeur=4", "remise=0", "navigateur=false"])
  ensure
    File.delete?(probe) if probe
  end

  it "compile le paquet de la saisie au clavier et le charge après le runtime (D-UI-027)" do
    PartiduoUi::OpalBuild.entries.should contain("entry")
    javascript = File.read(File.join(PartiduoUi::OpalBuild::OUTPUT, "entry.js"))
    javascript.should contain("Opal.modules[\"partiduo_ui/entry/keys\"]")
    javascript.should_not contain("var Opal = global_object.Opal = {};")
    File.size(File.join(PartiduoUi::OpalBuild::OUTPUT, "entry.js")).should be < 50_000
    {"entries/form.html", "invoicing/edit.html"}.each do |name|
      template = File.read(PartiduoUi::SpecSupport.path("src", "ui", "templates", "ui", name))
      template.index!("opal/runtime.js").should be < template.index!("opal/entry.js")
    end
  end

  it "exécute la règle des touches de saisie : Entrée, Alt+↓, Ctrl+Entrée" do
    engine = PartiduoUi::SpecSupport.javascript_engine
    pending!("aucun moteur JavaScript autonome (JavaScriptCore) ; PARTIDUO_JS_ENGINE pour en indiquer un") unless engine

    probe = File.tempname("partiduo-keys", ".js")
    File.write(probe, <<-JS)
      var Keys = Opal.PartiduoUi.Entry.Keys;
      function show(value) { return value === Opal.nil ? "nil" : value.toString(); }
      print("entree=" + show(Keys.$action("Enter", false, false, false, false, "input", "text")));
      print("ctrl=" + show(Keys.$action("Enter", true, false, false, false, "input", "text")));
      print("cmd=" + show(Keys.$action("Enter", false, true, false, false, "select", "")));
      print("alt=" + show(Keys.$action("ArrowDown", false, false, true, false, "input", "text")));
      print("bas=" + show(Keys.$action("ArrowDown", false, false, false, false, "input", "text")));
      print("zone=" + show(Keys.$action("Enter", false, false, false, false, "textarea", "")));
      print("bouton=" + show(Keys.$action("Enter", false, false, false, false, "button", "submit")));
      print("case=" + show(Keys.$action("Enter", false, false, false, false, "input", "checkbox")));
      print("maj=" + show(Keys.$action("Enter", false, false, false, true, "input", "text")));
      print("liste=" + show(Keys.$action("Enter", false, false, false, false, "select", "")));
      JS

    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(engine, [File.join(PartiduoUi::OpalBuild::OUTPUT, "runtime.js"),
                                  File.join(PartiduoUi::OpalBuild::OUTPUT, "entry.js"), probe], output: output, error: error)
    status.success?.should be_true, "#{error}#{output}"
    output.to_s.lines.should eq(["entree=next", "ctrl=save", "cmd=save", "alt=add_line", "bas=nil", "zone=nil",
                                 "bouton=nil", "case=nil", "maj=nil", "liste=next"])
  ensure
    File.delete?(probe) if probe
  end

  it "monte la saisie au clavier sur un formulaire et réagit aux touches (DOM simulé)" do
    engine = PartiduoUi::SpecSupport.javascript_engine
    pending!("aucun moteur JavaScript autonome (JavaScriptCore) ; PARTIDUO_JS_ENGINE pour en indiquer un") unless engine

    dom = File.tempname("partiduo-entry-dom", ".js")
    File.write(dom, <<-JS)
      var active = null, log = [];
      function CustomEvent(type, options) { this.type = type; this.bubbles = options && options.bubbles; }
      function El(tag, attrs) { this.tagName = tag.toUpperCase(); this.attrs = attrs || {}; this.listeners = {}; this.parent = null; this.children = []; this.value = ""; }
      El.prototype.getAttribute = function (n) { return n in this.attrs ? this.attrs[n] : null; };
      El.prototype.setAttribute = function (n, v) { this.attrs[n] = String(v); };
      El.prototype.hasAttribute = function (n) { return n in this.attrs; };
      El.prototype.addEventListener = function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); };
      El.prototype.dispatchEvent = function (e) { var self = this; (this.listeners[e.type] || []).forEach(function (f) { f(e); }); if (e.bubbles && this.parent) this.parent.dispatchEvent(e); return true; };
      El.prototype.append = function (child) { child.parent = this; this.children.push(child); return child; };
      El.prototype.remove = function () { var list = this.parent.children; list.splice(list.indexOf(this), 1); this.parent = null; };
      El.prototype.focus = function () { active = this; };
      El.prototype.select = function () {};
      El.prototype.click = function () { if ("data-pd-add-line" in this.attrs) log.push("add"); this.dispatchEvent(event("click", this)); };
      El.prototype.requestSubmit = function () { log.push("submit"); };
      El.prototype.matches = function (s) {
        if (s === "tr") return this.tagName === "TR";
        if (s === "tr[data-pd-line]") return this.tagName === "TR" && "data-pd-line" in this.attrs;
        if (s === "input") return this.tagName === "INPUT";
        if (s.charAt(0) === "[" && s.charAt(s.length - 1) === "]") return s.slice(1, -1) in this.attrs;
        if (s.indexOf("input:not") === 0) return (this.tagName === "INPUT" && this.attrs.type !== "hidden" && this.attrs.tabindex !== "-1") || this.tagName === "SELECT";
        return false;
      };
      El.prototype.all = function (s, found) { this.children.forEach(function (c) { if (c.matches(s)) found.push(c); c.all(s, found); }); return found; };
      El.prototype.querySelectorAll = function (s) { var f = this.all(s, []); return { length: f.length, item: function (i) { return f[i]; } }; };
      El.prototype.querySelector = function (s) { return this.all(s, [])[0] || null; };
      El.prototype.closest = function (s) { var n = this; while (n) { if (n.matches(s)) return n; n = n.parent; } return null; };
      function event(type, target, extra) {
        var e = { type: type, target: target, bubbles: true, prevented: false, preventDefault: function () { this.prevented = true; } };
        for (var k in (extra || {})) e[k] = extra[k];
        return e;
      }
      var form = new El("form", {"data-pd-entry": ""});
      var date = form.append(new El("input", {id: "date"}));
      var tbody = form.append(new El("tbody"));
      function line(n) {
        var tr = tbody.append(new El("tr", {"data-pd-line": ""}));
        var a = tr.append(new El("td")).append(new El("input", {id: "a" + n}));
        tr.append(new El("td")).append(new El("input", {id: "l" + n}));
        tr.append(new El("td")).append(new El("button", {"data-pd-del-line": "", tabindex: "-1", type: "submit"}));
        return a;
      }
      line(0); line(1);
      var add = form.append(new El("button", {"data-pd-add-line": "", type: "submit"}));
      add.addEventListener("click", function () { line(2); form.dispatchEvent(event("htmx:afterSettle", form)); });
      form.addEventListener("pd:lines", function () { log.push("lines"); });
      var document = new El("document");
      document.readyState = "complete";
      document.querySelectorAll = function (s) { var f = s === "[data-pd-entry]" ? [form] : []; return { length: f.length, item: function (i) { return f[i]; } }; };
      function press(el, key, extra) { el.focus(); var e = event("keydown", el, extra || {}); e.key = key; el.dispatchEvent(e); return e; }
      function id() { return active ? active.attrs.id : "none"; }
      JS

    probe = File.tempname("partiduo-entry-probe", ".js")
    File.write(probe, <<-JS)
      print("monte=" + form.hasAttribute("data-opal-mounted"));
      var e1 = press(date, "Enter"); print("entree=" + id() + " empeche=" + e1.prevented);
      press(tbody.children[0].children[1].children[0], "Enter"); print("ligne=" + id());
      press(tbody.children[1].children[1].children[0], "Enter"); print("fin=" + id() + " lignes=" + tbody.children.length);
      press(date, "ArrowDown", {altKey: true}); print("alt=" + id() + " lignes=" + tbody.children.length);
      var e2 = press(date, "a"); print("autre=" + e2.prevented);
      press(date, "Enter", {ctrlKey: true});
      tbody.children[0].children[2].children[0].click(); print("retrait=" + tbody.children.length);
      print("journal=" + log.join(","));
      JS

    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(engine, [dom, File.join(PartiduoUi::OpalBuild::OUTPUT, "runtime.js"),
                                  File.join(PartiduoUi::OpalBuild::OUTPUT, "entry.js"), probe], output: output, error: error)
    status.success?.should be_true, "#{error}#{output}"
    output.to_s.lines.should eq(["monte=true", "entree=a0 empeche=true", "ligne=a1", "fin=a2 lignes=3", "alt=a2 lignes=4",
                                 "autre=false", "retrait=3", "journal=add,add,submit,lines"])
  ensure
    File.delete?(dom) if dom
    File.delete?(probe) if probe
  end
end
