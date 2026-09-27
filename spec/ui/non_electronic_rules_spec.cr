# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Factures non électroniques (ADR-004 D9) dans l'interface : cas limites,
# permissions et sécurité de la pièce jointe servie en ligne (lot E,
# testeur).

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books
private alias Accounts = PartiduoUi::Accounts

private XML_PAYLOAD = %(<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><script>alert(1)</script></html>)

private def stored(filename : String, type : String, content : String | Bytes) : Int64
  bytes = content.is_a?(String) ? content.to_slice : content
  Partiduo::Api::Core.store_attachment(Books.system,
    Partiduo::Api::Core::AttachmentInput.new(filename, type, IO::Memory.new(bytes))).value!.id
end

# Utilisateur `bob@example.com` dont le profil ne porte que `permissions`.
private def restricted(permissions : Array(String)) : PartiduoUi::Browser
  profile = Accounts.profile("Restreint", permissions)
  Accounts.create("bob@example.com", profile: nil, profile_id: profile)
  Accounts.signed_in("bob@example.com")
end

private def invoice_with_customer : Inv::DocumentView
  customer = Books.card("CUSTOMER", "Jeanne Martin", "CLI-MARTIN")
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  item = Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(
    category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil", code: "CONSEIL", unit_code: "HUR",
    sale_price: Books.d("80"), vat_rate_id: rate.id)).value!
  Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
    lines: [Inv::LineInput.new(item_card_id: item.id, quantity: Books.d("1"))])).value!
end

describe "Factures non électroniques : règles de l'interface (lot E)" do
  it "télécharge au lieu d'afficher une pièce qui n'est ni PDF ni image, sans deviner le type" do
    browser = Books.admin
    xml = browser.get("/attachments/#{stored("facture.xml", "application/xml", XML_PAYLOAD)}")
    xml.status.should eq(200)
    xml.headers["Content-Disposition"].should start_with("attachment;")
    xml.headers["X-Content-Type-Options"].should eq("nosniff")
    text = browser.get("/attachments/#{stored("releve.csv", "text/csv", "date;montant\n")}")
    text.headers["Content-Disposition"].should start_with("attachment;")

    png = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
    image = browser.get("/attachments/#{stored("ticket.png", "image/png", png)}")
    image.headers["Content-Disposition"].should start_with("inline;")
    image.headers["X-Content-Type-Options"].should eq("nosniff")
  end

  it "nettoie le nom du fichier dans l'en-tête Content-Disposition" do
    browser = Books.admin
    id = stored("fac\"ture\\ 2026.pdf", "application/pdf", "%PDF-1.7\n%%EOF\n")
    browser.get("/attachments/#{id}").headers["Content-Disposition"].should eq(%(inline; filename="2026.pdf"))
  end

  it "refuse la pièce jointe à un anonyme, à un profil sans droit, et une pièce inconnue" do
    admin = Books.admin
    id = stored("facture.pdf", "application/pdf", "%PDF-1.7\n%%EOF\n")
    anonymous = PartiduoUi::Browser.new.get("/attachments/#{id}")
    anonymous.status.should eq(302)
    anonymous.headers["Location"].should start_with("/login")
    admin.get("/attachments/999999").status.should eq(404)
    restricted(["accounting.entry.read"]).get("/attachments/#{id}").status.should eq(403)
  end

  it "refuse l'écran de la facture reçue sans le droit de saisie" do
    Books.admin
    browser = restricted(["accounting.entry.read", "accounting.ledger.read", "core.attachment.read"])
    browser.get("/accounting/entries/received-invoice").status.should eq(403)
    browser.post("/accounting/entries/received-invoice/check", {"invoice_number" => "X"},
      {"HX-Request" => "true"}).status.should eq(403)
  end

  it "signale un canal inconnu et un brouillon marqué envoyé, sans rien changer" do
    browser = Books.admin
    draft = invoice_with_customer
    marked = browser.post("/invoicing/documents/#{draft.id}/mark-sent")
    browser.follow(marked).html.should contain("abord le document")
    Inv.document(Books.system, draft.id).sent_at.should be_nil

    invoice = Inv.issue(Books.system, draft.id, Inv::IssueInput.new(Books.date("2026-09-15"))).value!
    refused = browser.post("/invoicing/documents/#{invoice.id}/channel", {"issue_channel" => "fax"})
    browser.follow(refused).html.should contain("mission inconnu : fax")
    Inv.document(Books.system, invoice.id).issue_channel.should eq(invoice.issue_channel)

    browser.post("/invoicing/documents/#{invoice.id}/mark-sent").status.should eq(302)
    late = browser.post("/invoicing/documents/#{invoice.id}/channel", {"issue_channel" => "email"})
    browser.follow(late).html.should contain("Document déjà envoyé")
    Inv.document(Books.system, invoice.id).issue_channel.should eq(invoice.issue_channel)
  end

  it "exige le droit d'envoyer pour marquer envoyé, et celui d'écrire pour changer le canal" do
    Books.admin
    draft = invoice_with_customer
    invoice = Inv.issue(Books.system, draft.id, Inv::IssueInput.new(Books.date("2026-09-15"))).value!
    reader = restricted(["invoicing.invoice.read"])
    reader.post("/invoicing/documents/#{invoice.id}/mark-sent").status.should eq(403)
    reader.post("/invoicing/documents/#{invoice.id}/channel", {"issue_channel" => "paper"}).status.should eq(403)
    Inv.document(Books.system, invoice.id).sent_at.should be_nil
    page = reader.get("/invoicing/documents/#{invoice.id}").html
    page.should_not contain(%(action="/invoicing/documents/#{invoice.id}/mark-sent"))
  end
end
