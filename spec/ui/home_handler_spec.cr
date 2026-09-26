# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe PartiduoUi::HomeHandler do
  it "affiche la page d'accueil avec la coquille, HTMX et l'exemple Opal" do
    response = Marten::Spec.client.get(Marten.routes.reverse("home"), headers: {"Accept-Language" => "fr"})

    response.status.should eq(200)
    response.content_type.should contain("text/html")
    body = response.content
    body.should contain(%(<html lang="fr">))
    body.should contain("Partiduo")
    body.should contain("Démonstration Opal")
    body.should contain(%(src="/assets/ui/js/htmx.min.js"))
    body.should contain(%(src="/assets/ui/js/opal/demo.js"))
    body.should contain(%(href="/assets/ui/css/theme.css"))
    body.should contain("data-opal-counter")
    body.should contain("/assets/ui/icons/sprite.svg#layout-dashboard")
    body.should contain(Partiduo::API_VERSION)
  end

  it "suit la langue du navigateur (fr, en, nl)" do
    {"fr" => "Accueil", "en" => "Home", "nl" => "Startpagina"}.each do |locale, title|
      response = Marten::Spec.client.get("/", headers: {"Accept-Language" => locale})
      response.content.should contain("<h1>#{title}</h1>")
      response.content.should_not contain("translation missing")
    end
  end
end
