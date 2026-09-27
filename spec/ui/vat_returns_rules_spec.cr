# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 4 — écrans des déclarations de TVA, cas limites : refus du contrat
# rendus sur place (déclaration périmée, liquidation d'un brouillon),
# déclaration inconnue, listing belge, filtres de l'historique, règles
# saisies sans filtre, droit de saisir pour la liquidation.

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private CA3_Q1 = "form=fr_ca3&year=2026&periodicity=quarter&number=1"

private def french_books : PartiduoUi::Browser
  browser = Books.admin
  customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
  Books.sale(customer.code, "100", "2026-03-10")
  browser
end

private def draft(input : String = CA3_Q1) : Int64
  params = URI::Params.parse(input)
  Acc.create_vat_return(Books.system, Acc::VatReturnInput.new(form: params["form"], year: params["year"].to_i,
    periodicity: params["periodicity"], number: params["number"].to_i)).value!.id || raise "déclaration sans identifiant"
end

private def declarer(*permissions : String) : PartiduoUi::Browser
  profile = PartiduoUi::Accounts.profile("Profil TVA", permissions.to_a)
  PartiduoUi::Accounts.create("tva@example.com", profile: nil, profile_id: profile)
  PartiduoUi::Accounts.signed_in("tva@example.com")
end

describe "Déclarations de TVA (lot 4), cas limites" do
  it "refuse de clore une déclaration dont les écritures ont changé et le dit sur le formulaire" do
    browser = french_books
    id = draft
    Books.sale("CLI-MOREL", "40", "2026-03-12")
    refused = browser.post("/accounting/vat/returns/#{id}/close", {"date" => ""})
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("accounting.errors.vat_return.stale"))
    Acc.vat_return(Books.system, id).closed?.should be_false
  end

  it "refuse de liquider un brouillon, avec le message du contrat" do
    browser = french_books
    id = draft
    refused = browser.post("/accounting/vat/returns/#{id}/settle", {"date" => ""})
    refused.status.should eq(422)
    refused.html.should contain(I18n.t("accounting.errors.vat_return.not_closed"))
    Acc.vat_return(Books.system, id).settlement_entry_id.should be_nil
  end

  it "répond 404 pour une déclaration inconnue" do
    browser = french_books
    %w[/accounting/vat/returns/999999 /accounting/vat/returns/999999/edit /accounting/vat/returns/999999/control
      /accounting/vat/returns/999999/close /accounting/vat/returns/999999/file?format=csv].each do |path|
      {path, browser.get(path).status}.should eq({path, 404})
    end
  end

  it "prépare le listing belge des clients assujettis, sans proposer de liquidation" do
    browser = Books.admin("be")
    customer = Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(
      category_id: PartiduoUi::Reference.category("CUSTOMER").id, name: "Brasserie Lambert", code: "CLI-LAMBERT",
      vat_number: "BE0417497106")).value!
    input = Acc::DocumentInput.new(ledger_id: Books.ledger("V01").id, date: Books.date("2026-02-10"), third_party: customer.code,
      lines: [Acc::DocumentLineInput.new(amount: Books.d("300"), account: "700", vat_rate: "21G")], label: "Facture")
    Acc.post_sale(Books.system, input).value!

    page = browser.get("/accounting/vat?f=1&form=be_client_listing&year=2026&periodicity=year&number=1")
    page.status.should eq(200)
    page.html.should contain("BE0417497106")
    page.html.should contain("Brasserie Lambert")

    id = draft("form=be_client_listing&year=2026&periodicity=year&number=1")
    close = browser.get("/accounting/vat/returns/#{id}/close").html
    close.should_not contain(%(name="settle"))
    browser.post("/accounting/vat/returns/#{id}/close", {"confirm" => "1"}).status.should eq(302)
    Acc.vat_return(Books.system, id).closed?.should be_true
    browser.get("/accounting/vat/returns/#{id}").html.should_not contain("/settle")
  end

  it "filtre l'historique par formulaire et par année" do
    browser = french_books
    ca3 = draft
    ca12 = draft("form=fr_ca12&year=2026&periodicity=year&number=1")
    filtered = browser.get("/accounting/vat/returns?form=fr_ca12&year=2026").html
    filtered.should contain(%(href="/accounting/vat/returns/#{ca12}"))
    filtered.should_not contain(%(href="/accounting/vat/returns/#{ca3}"))
    browser.get("/accounting/vat/returns?year=2025").html.should_not contain(%(href="/accounting/vat/returns/#{ca3}"))
  end

  it "garde une règle sans filtre dont la source n'est pas celle par défaut" do
    browser = french_books
    data = {"count" => "1", "rules[0].source" => "deductible", "rules[0].sign" => "all", "rules[0].operation" => "add"}
    browser.post("/accounting/vat/rules/fr/20", data).status.should eq(302)
    stored = Acc.vat_box_rules(Books.system, "fr").select(&.box.==("20"))
    stored.map(&.source).should eq(["deductible"])
  end

  it "renvoie les erreurs d'une règle sur sa ligne du formulaire" do
    browser = french_books
    data = {"count" => "2", "rules[0].remove" => "1", "rules[0].source" => "base", "rules[0].accounts" => "706",
            "rules[1].source" => "base", "rules[1].ledger_code" => "ZZ9"}
    refused = browser.post("/accounting/vat/rules/fr/08.base", data)
    refused.status.should eq(422)
    refused.html.should contain("ZZ9")
    refused.html.should contain(%(aria-invalid="true"))
    Acc.vat_box_rules(Books.system, "fr").all?(&.default).should be_true
  end

  it "sans le droit de saisir, clôt sans liquider mais refuse l'écriture de liquidation" do
    french_books
    id = draft
    browser = declarer("accounting.vat.declare")
    browser.post("/accounting/vat/returns/#{id}/close", {"settle" => "1", "date" => ""}).status.should eq(403)
    Acc.vat_return(Books.system, id).closed?.should be_false
    browser.post("/accounting/vat/returns/#{id}/close", {"date" => ""}).status.should eq(302)
    Acc.vat_return(Books.system, id).closed?.should be_true
  end
end
