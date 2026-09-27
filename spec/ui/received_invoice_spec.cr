# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Factures non électroniques (ADR-004 D9) dans l'interface : saisie d'une
# facture d'achat papier avec la pièce jointe à côté, canal d'émission des
# factures de vente.

private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books

private PDF = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

class PartiduoUi::Browser
  # Formulaire `multipart/form-data` (fichiers joints) : `files` associe le
  # nom du champ à {nom du fichier, type, contenu}.
  def post_multipart(path : String, fields : Hash(String, String),
                     files = {} of String => {String, String, String}) : Marten::HTTP::Response
    io = IO::Memory.new
    builder = HTTP::FormData::Builder.new(io, "partiduo-spec-boundary")
    fields.each { |name, value| builder.field(name, value) }
    files.each do |name, (filename, type, content)|
      builder.file(name, IO::Memory.new(content), HTTP::FormData::FileMetadata.new(filename: filename),
        HTTP::Headers{"Content-Type" => type})
    end
    builder.finish
    content_type = builder.content_type
    perform { |client| client.post(path, data: io.to_s, content_type: content_type, headers: @headers) }
  end
end

private def received_values(supplier : String, extra = {} of String => String) : Hash(String, String)
  {"ledger_id" => Books.ledger("A01").id.to_s, "date" => "2026-09-24", "receipt" => "", "label" => "Abonnement fibre",
   "third_party" => supplier, "due_date" => "", "invoice_number" => "FB-2026-0918-4471", "invoice_date" => "2026-09-18",
   "line-0-account" => "603", "line-0-label" => "", "line-0-amount" => "72", "line-0-vat_rate" => "NOR",
   "line-1-account" => "", "line-1-label" => "", "line-1-amount" => "", "line-1-vat_rate" => ""}.merge(extra)
end

private def pdf_file : Hash(String, {String, String, String})
  {"attachment_file" => {"facture-orange.pdf", "application/pdf", PDF}}
end

describe "Facture d'achat reçue hors plateforme (ADR-004 D9)" do
  it "affiche la saisie d'achat avec le panneau « Facture reçue » à côté, reliée au menu" do
    browser = Books.admin
    page = browser.get("/accounting/entries/received-invoice").html
    page.should contain("<h1>Facture d'achat reçue hors plateforme</h1>")
    page.should contain(%(enctype="multipart/form-data"))
    page.should contain("Reçue hors plateforme")
    page.should contain(%(<h2 id="pd-received-title">Facture reçue</h2>))
    page.should contain(%(name="invoice_number" form="pd-entry-form"))
    page.should contain(%(name="attachment_file" form="pd-entry-form"))
    page.should contain(%(hx-post="/accounting/entries/received-invoice/upload"))
    page.should contain(%(hx-post="/accounting/entries/received-invoice/check"))
    page.should contain(%(hx-params="not attachment_file"))
    page.should contain(%(<option value="#{Books.ledger("A01").id}" selected>A01 ·))
    browser.get("/accounting/entries/purchase").html.should contain(%(<a href="/accounting/entries/received-invoice">))
  end

  it "dépose le fichier dès qu'il est choisi et l'affiche à côté ; sert la pièce dans un cadre de même origine" do
    browser = Books.admin
    fragment = browser.post_multipart("/accounting/entries/received-invoice/upload", {} of String => String, pdf_file).html
    id = fragment.match!(/name="attachment_id" value="(\d+)" form="pd-entry-form"/)[1]
    fragment.should contain(%(<iframe class="pd-attachment-preview mt-2" src="/attachments/#{id}"))
    fragment.should contain("· 1 Ko</span>")
    fragment.should contain("facture-orange.pdf")

    file = browser.get("/attachments/#{id}")
    file.status.should eq(200)
    file.content.should eq(PDF)
    file.content_type.should eq("application/pdf")
    file.headers["Content-Disposition"].should start_with("inline")
    file.headers["X-Frame-Options"].should eq("SAMEORIGIN")

    refused = browser.post_multipart("/accounting/entries/received-invoice/upload", {} of String => String,
      {"attachment_file" => {"facture.pdf", "application/pdf", "pas un PDF"}}).html
    refused.should_not contain(%(name="attachment_id"))
    refused.should contain("pd-field-errors")
  end

  it "enregistre la facture avec sa pièce jointe, puis la montre sur l'écriture" do
    browser = Books.admin
    supplier = Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    response = browser.post_multipart("/accounting/entries/received-invoice", received_values(supplier.code), pdf_file)
    response.status.should eq(302)
    response.headers["Location"].should match(%r{\A/accounting/entries/\d+\z})
    page = browser.follow(response).html
    page.should contain("Facture FB-2026-0918-4471 enregistrée")
    page.should contain("Facture reçue")
    page.should contain("Reçue hors plateforme")
    page.should contain("86,40 EUR")
    page.should contain("Ouvrir la pièce jointe")

    entry_id = response.headers["Location"].split('/').last.to_i64
    invoice = Acc.received_invoice_for_entry(Books.system, entry_id) || raise "facture absente"
    invoice.off_platform?.should be_true
    invoice.invoice_date.should eq(Books.date("2026-09-18"))
    Acc.entry(Books.system, entry_id).attachment_id.should eq(invoice.attachment_id)
  end

  it "refuse un doublon et garde la pièce déjà déposée ; le contrôle instantané le signale" do
    browser = Books.admin
    supplier = Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    browser.post_multipart("/accounting/entries/received-invoice", received_values(supplier.code), pdf_file).status.should eq(302)

    live = browser.post("/accounting/entries/received-invoice/check",
      received_values(supplier.code, {"invoice_number" => "fb 2026 0918 4471"}), {"HX-Request" => "true"}).html
    live.should contain("déjà enregistrée pour ce fournisseur et ce montant")

    again = browser.post_multipart("/accounting/entries/received-invoice", received_values(supplier.code), pdf_file)
    again.status.should eq(422)
    body = again.html
    body.should contain("Facture FB-2026-0918-4471 déjà enregistrée pour ce fournisseur et ce montant")
    body.should match(/name="attachment_id" value="\d+" form="pd-entry-form"/)
    body.should contain(%(value="FB-2026-0918-4471"))
  end

  it "exige le numéro et la pièce jointe ; le contrôle instantané calcule l'écriture sans pièce" do
    browser = Books.admin
    supplier = Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    live = browser.post("/accounting/entries/received-invoice/check", received_values(supplier.code),
      {"HX-Request" => "true"}).html
    live.should contain("86,40")
    live.should_not contain("Joignez la facture")

    response = browser.post_multipart("/accounting/entries/received-invoice",
      received_values(supplier.code, {"invoice_number" => ""}))
    response.status.should eq(422)
    response.html.should contain("Indiquez le numéro de la facture du fournisseur")
    response.html.should contain("Joignez la facture (PDF ou image)")
    Acc.count_entries(Books.system).should eq(0)
  end
end

describe "Canal d'émission des factures (ADR-004 D9)" do
  it "propose le canal selon le client dans l'édition, garde le canal choisi, le change jusqu'à l'envoi" do
    browser = Books.admin
    Books.card("CUSTOMER", "Jeanne Martin", "CLI-MARTIN")
    rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
    Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(
      category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil (heure)", code: "CONSEIL", unit_code: "HUR",
      sale_price: Books.d("80"), vat_rate_id: rate.id)).value!
    values = {"kind" => "invoice", "customer" => "CLI-MARTIN", "issue_date" => "", "delivery_date" => "", "due_date" => "",
              "operation_category" => "services", "global_discount" => "", "buyer_reference" => "", "order_reference" => "",
              "notes" => "", "issue_channel" => "", "b2c" => "", "line-0-item" => "CONSEIL", "line-0-description" => "",
              "line-0-quantity" => "1", "line-0-unit" => "", "line-0-unit_price" => "", "line-0-discount" => "",
              "line-0-vat_rate_id" => ""}

    form = browser.get("/invoicing/documents/new?kind=invoice").html
    form.should contain(%(name="issue_channel"))
    form.should contain(%(<option value="platform">Plateforme agréée</option>))
    browser.get("/invoicing/documents/new?kind=quote").html.should_not contain(%(name="issue_channel"))

    response = browser.post("/invoicing/documents/new", values.merge({"issue_channel" => "email"}))
    response.status.should eq(302)
    document = Inv.documents(Books.system, Inv::DocumentQuery.new(kind: "invoice")).first
    {document.issue_channel, document.b2c}.should eq({"email", true})
    edit = browser.get("/invoicing/documents/#{document.id}/edit").html
    edit.should contain(%(<option value="email" selected>Courriel</option>))
    edit.should contain("Proposé : Papier · B2C — Client particulier")

    Inv.issue(Books.system, document.id, Inv::IssueInput.new(Books.date("2026-09-15"))).value!
    page = browser.get("/invoicing/documents/#{document.id}").html
    page.should contain(%(<h2 id="pd-channel-title">Canal d'émission</h2>))
    page.should contain(%(action="/invoicing/documents/#{document.id}/channel"))
    page.should contain(%(action="/invoicing/documents/#{document.id}/mark-sent"))

    changed = browser.post("/invoicing/documents/#{document.id}/channel", {"issue_channel" => "paper", "b2c" => "1"})
    browser.follow(changed).html.should contain("Canal d'émission enregistré.")
    Inv.document(Books.system, document.id).issue_channel.should eq("paper")

    sent = browser.post("/invoicing/documents/#{document.id}/mark-sent")
    after = browser.follow(sent).html
    after.should contain("Document marqué comme envoyé.")
    after.should_not contain(%(action="/invoicing/documents/#{document.id}/channel"))
    after.should contain("Envoyé le")
    Inv.document(Books.system, document.id).status.should eq("sent")
  end
end
