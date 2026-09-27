# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — écrans du Suivi : types d'action, étiquettes, actions (création,
# modification, état, commentaires, actions liées, opérations rattachées),
# recherche, rappels, export.

private alias Fup = Partiduo::Api::Followup
private alias Books = PartiduoUi::Books

private def followup_books : PartiduoUi::Browser
  browser = Books.admin
  Partiduo::Api::Modules.activate(Books.system, "FOLLOWUP").success?.should be_true
  browser
end

private def action_type(code : String = "DI") : Fup::ActionTypeView
  Fup.create_action_type(Books.system, Fup::ActionTypeInput.new(code, "Document interne")).value!
end

describe "Suivi (lot 6)" do
  it "n'expose aucun écran quand le module est inactif" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "FOLLOWUP")
    %w[/followup/actions /followup/actions/new /followup/reminders /followup/types /followup/tags].each do |path|
      browser.get(path).status.should eq(404)
    end
  end

  it "gère les types d'action et les étiquettes par les formulaires" do
    browser = followup_books
    browser.get("/followup/types").html.should contain("Aucun type d'action")
    browser.post("/followup/types/new", {"code" => "di", "label" => "Document interne", "next_number" => "5"}).status.should eq(302)
    type = Fup.action_types(Books.system).first
    type.code.should eq("DI")
    type.next_number.should eq(5)
    twice = browser.post("/followup/types/new", {"code" => "DI", "label" => "Autre"})
    twice.status.should eq(422)
    twice.html.should contain("Le préfixe DI est déjà utilisé.")
    browser.post("/followup/types/#{type.id}/edit", {"code" => "DI", "label" => "Interne", "next_number" => "7"}).status.should eq(302)
    Fup.action_type(Books.system, type.id).label.should eq("Interne")

    browser.post("/followup/types/defaults").status.should eq(302)
    Fup.action_types(Books.system).map(&.code).should contain("FAC")

    browser.post("/followup/tags/new", {"label" => "Urgent", "color" => "3", "active" => "1"}).status.should eq(302)
    tag = Fup.tags(Books.system).first
    tag.color.should eq(3)
    tag.active.should be_true
    browser.post("/followup/tags/#{tag.id}/edit", {"label" => "Urgent", "color" => "3"}).status.should eq(302)
    Fup.tags(Books.system).first.active.should be_false
    browser.post("/followup/tags/#{tag.id}/delete").status.should eq(302)
    Fup.tags(Books.system).should be_empty
    browser.post("/followup/types/#{type.id}/delete").status.should eq(302)
  end

  it "crée, consulte, commente, clôture et recherche une action" do
    browser = followup_books
    type = action_type
    tag = Fup.create_tag(Books.system, Fup::TagInput.new("Client")).value!
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")

    unknown = browser.post("/followup/actions/new", {"action_type_id" => type.id.to_s, "date" => "2026-03-10",
                                                     "card" => "INCONNU", "priority" => "2", "state" => "todo"})
    unknown.status.should eq(422)
    unknown.html.should contain("Fiche inconnue : INCONNU.")

    created = browser.post("/followup/actions/new", {
      "action_type_id" => type.id.to_s, "title" => "Relance devis", "date" => "2026-03-10", "hour" => "09:30",
      "priority" => "1", "state" => "todo", "remind_on" => "2026-03-01", "card" => customer.code,
      "tag-#{tag.id}" => "1", "comment" => "Appeler lundi",
    })
    created.status.should eq(302)
    action = Fup.actions(Books.system).first
    created.headers["Location"].should eq("/followup/actions/#{action.id}")
    action.reference.should eq("DI-1")

    page = browser.get("/followup/actions/#{action.id}").html
    page.should contain("Relance devis")
    page.should contain("Appeler lundi")
    page.should contain("Atelier Morel")
    page.should contain("Client")

    browser.post("/followup/actions/#{action.id}/comment", {"text" => "Rappel fait"}).status.should eq(302)
    Fup.action(Books.system, action.id).comments.map(&.text).should eq(["Appeler lundi", "Rappel fait"])

    list = browser.get("/followup/actions?q=relance").html
    list.should contain("DI-1")
    list.should contain("pd-row-warning")
    browser.get("/followup/actions?q=absent").html.should_not contain(%(href="/followup/actions/#{action.id}"))
    browser.get("/followup/reminders").html.should contain("DI-1")
    # Rappel en retard repris dans « À traiter » du tableau de bord.
    dashboard = browser.get("/").html
    dashboard.should contain("1 rappel du suivi à traiter")
    dashboard.should contain("DI-1 · Relance devis")
    browser.get("/cards/#{customer.id}").html.should contain("/followup/actions?card=CLI-MOREL&state=all")

    csv = browser.get("/followup/actions?format=csv")
    csv.content_type.should start_with("text/csv")
    csv.content.should contain("DI-1")

    browser.post("/followup/actions/#{action.id}/state?state=closed").status.should eq(302)
    Fup.action(Books.system, action.id).state.should eq("closed")
    browser.get("/followup/actions").html.should_not contain("DI-1")
    browser.get("/followup/actions?state=all").html.should contain("DI-1")

    edited = browser.post("/followup/actions/#{action.id}/edit", {
      "action_type_id" => type.id.to_s, "title" => "Relance devis n° 2", "date" => "2026-03-12", "priority" => "2",
      "state" => "follow", "card" => "", "concerned" => customer.code,
    })
    edited.status.should eq(302)
    updated = Fup.action(Books.system, action.id)
    updated.title.should eq("Relance devis n° 2")
    updated.internal?.should be_true
    updated.concerned.map(&.code).should eq([customer.code])
    updated.tags.should be_empty

    browser.post("/followup/actions/#{action.id}/delete").status.should eq(302)
    Fup.actions(Books.system, Fup::ActionQuery.new(open_only: false)).should be_empty
  end

  it "lie deux actions et rattache une opération" do
    browser = followup_books
    type = action_type
    first = Fup.create_action(Books.system, Fup::ActionInput.new(type.id, Books.date("2026-03-10"), title: "Premier")).value!
    second = Fup.create_action(Books.system, Fup::ActionInput.new(type.id, Books.date("2026-03-11"), title: "Second")).value!

    missing = browser.post("/followup/actions/#{first.id}/relate", {"reference" => "XX-9"})
    missing.status.should eq(422)
    missing.html.should contain("Aucune action ne porte la référence XX-9.")
    browser.post("/followup/actions/#{first.id}/relate", {"reference" => second.reference}).status.should eq(302)
    Fup.action(Books.system, first.id).related.map(&.id).should eq([second.id])
    browser.get("/followup/actions/#{second.id}").html.should contain(%(href="/followup/actions/#{first.id}"))
    browser.post("/followup/actions/#{first.id}/unrelate/#{second.id}").status.should eq(302)
    Fup.action(Books.system, first.id).related.should be_empty

    bad = browser.post("/followup/actions/#{first.id}/link", {"reference" => "écriture 4"})
    bad.status.should eq(422)
    Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    entry = Books.sale("CLI-MOREL", "100")
    reference = "entry:#{entry.id}"
    browser.post("/followup/actions/#{first.id}/link", {"reference" => reference}).status.should eq(302)
    page = browser.get("/followup/actions/#{first.id}").html
    page.should contain(reference)
    page.should contain(%(href="/accounting/entries/#{entry.id}"))
    browser.get("/accounting/entries/#{entry.id}").html.should contain(%(href="/followup/actions/#{first.id}"))
    browser.post("/followup/actions/#{first.id}/unlink?#{URI::Params.encode({"reference" => reference})}").status.should eq(302)
    Fup.action(Books.system, first.id).links.should be_empty
  end
end
