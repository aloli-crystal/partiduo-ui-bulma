# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Page d'accueil minimale : coquille de l'interface et exemple Opal.
  class HomeHandler < Marten::Handlers::Template
    template_name "ui/home.html"

    before_render :add_contract_version

    private def add_contract_version
      context[:api_version] = Partiduo::API_VERSION
    end
  end
end
