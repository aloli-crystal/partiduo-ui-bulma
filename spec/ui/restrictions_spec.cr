# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Droits par dépôt et actions de suivi réservées à un profil, dans
# l'interface (DECISIONS D-R5-015, D-R5-016 ; BLOCAGES B-SEC-001).

private alias Stk = Partiduo::Api::Stock
private alias Fup = Partiduo::Api::Followup
private alias Books = PartiduoUi::Books

describe "Restrictions par profil (interface)" do
  it "règle les droits d'un profil dépôt par dépôt, qui ne voit plus que les dépôts cités" do
    admin = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "STOCK").value!
    lyon = Stk.create_repository(Books.system, Stk::RepositoryInput.new("Entrepôt Lyon")).value!
    Stk.create_repository(Books.system, Stk::RepositoryInput.new("Annexe Nantes")).value!
    profile = PartiduoUi::Accounts.profile("Magasinier", %w[stock.movement.read stock.movement.write])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)

    admin.get("/stock/repositories").html.should contain(%(href="/stock/rights"))
    page = admin.get("/stock/rights?profile=#{profile}").html
    page.should contain("Droits par dépôt")
    page.should contain(%(name="access_#{lyon.id}"))
    page.should contain("Lecture et écriture")
    saved = admin.post("/stock/rights", {"profile" => profile.to_s, "access_#{lyon.id}" => "R"})
    saved.status.should eq(302)
    admin.follow(saved).html.should contain("Magasinier (restreint)")

    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    list = bob.get("/stock/repositories").html
    list.should contain("Entrepôt Lyon")
    list.should_not contain("Annexe Nantes")
    admin.post("/stock/rights", {"profile" => profile.to_s}).status.should eq(302)
    bob.get("/stock/repositories").html.should contain("Annexe Nantes")
  end

  it "réserve une action de suivi à un profil depuis le formulaire" do
    admin = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "FOLLOWUP").value!
    type = Fup.create_action_type(Books.system, Fup::ActionTypeInput.new("DI", "Document interne")).value!
    profile = PartiduoUi::Accounts.profile("Ventes", %w[followup.action.read followup.action.write])
    other = PartiduoUi::Accounts.profile("Comptabilité", %w[followup.action.read followup.action.write])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: other)

    form = admin.get("/followup/actions/new").html
    form.should contain(%(name="visible_profile_id"))
    form.should contain("Toute personne qui lit le suivi")
    created = admin.post("/followup/actions/new", {"action_type_id" => type.id.to_s, "title" => "Prime annuelle",
                                                   "date" => "20/09/2026", "priority" => "2", "state" => "todo",
                                                   "visible_profile_id" => profile.to_s})
    created.status.should eq(302)
    admin.follow(created).html.should contain("Visible par")
    action = Fup.actions(Books.system).first
    action.title.should eq("Prime annuelle")

    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    bob.get("/followup/actions").html.should_not contain("Prime annuelle")
    bob.get("/followup/actions/#{action.id}").status.should eq(404)
  end
end
