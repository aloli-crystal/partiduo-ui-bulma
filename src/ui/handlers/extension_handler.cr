# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Point d'entrée unique des interfaces d'extension (ADR-003 D3, ADR-005 D4) :
  # contrôle d'accès à partir du manifeste (`PartiduoUi::Extensions.authorize`),
  # puis appel du handler de l'extension. L'extension ne peut pas être
  # atteinte sans passer par ce contrôle : ses routes ne sont inscrites
  # qu'après celles-ci, pour le nommage.
  class ExtensionHandler < Handler
    def dispatch : Marten::HTTP::Response
      mount = Extensions[params["code"].to_s]?
      return ErrorPage.render(request, 404) if mount.nil?

      path = "/#{params["path"]?}"
      route_name = Extensions.route_name(mount.routes, path, mount.namespace)
      case Extensions.authorize(current, mount, route_name)
      in .allowed?    then call_extension(mount, path)
      in .login?      then Navigation.to_login(request)
      in .enrollment? then go(reverse("account_enrollment"))
      in .elevation?  then go(reverse("account_security"))
      in .not_found?  then ErrorPage.render(request, 404)
      in .forbidden?  then ErrorPage.render(request, 403)
      end
    end

    private def call_extension(mount : Extensions::Mount, path : String) : Marten::HTTP::Response
      match = mount.routes.resolve(path)
      match.handler.new(request, match.kwargs).process_dispatch
    rescue Marten::Routing::Errors::NoResolveMatch
      ErrorPage.render(request, 404)
    end
  end
end
