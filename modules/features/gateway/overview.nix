# The start page (Homepage) at home.<domain>: a tile for every service with a dashboard entry,
# grouped, linked to its route and with a status dot; live numbers where it sets a widget.
# Widget credentials come from secrets.json dashboard/<service>/<field>. Below the tiles, a row
# of links to the admin pages of what runs outside the cluster.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatMap
    concatStrings
    filterAttrs
    genAttrs
    head
    mapAttrsToList
    optionalAttrs
    replaceStrings
    sort
    toUpper
    unique
    ;
in
{
  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon) cluster services;
      ph = config.sops.placeholder;

      domain =
        if cluster.domain != null then
          cluster.domain
        else
          throw "cluster.toml: the gateway feature needs a domain";
      port = 8082;

      tiles = filterAttrs (_: service: service.dashboard != null && service.route != null) services;
      groups = unique (sort (a: b: a < b) (mapAttrsToList (_: service: service.dashboard.group) tiles));

      internal = route: "http://${route.address}:${toString route.port}";
      envName =
        name: field: "HOMEPAGE_VAR_${toUpper (replaceStrings [ "-" ] [ "_" ] "${name}_${field}")}";
      secretsOf = name: map (field: "dashboard/${name}/${field}") tiles.${name}.dashboard.secrets;

      tile = name: service: {
        ${service.dashboard.name} = {
          href = "https://${service.route.subdomain}.${domain}";
          inherit (service.dashboard) description icon;
          siteMonitor = internal service.route + service.dashboard.monitor;
        }
        // optionalAttrs (service.dashboard.widget != null) {
          widget = {
            url = internal service.route;
          }
          // service.dashboard.widget
          // genAttrs service.dashboard.secrets (field: "{{${envName name field}}}");
        };
      };
      inGroup =
        group:
        sort (a: b: head (attrNames a) < head (attrNames b)) (
          mapAttrsToList tile (filterAttrs (_: service: service.dashboard.group == group) tiles)
        );
    in
    {
      services.homepage-dashboard = {
        enable = true;
        listenPort = port;
        allowedHosts = "home.${domain}";
        environmentFiles = [ config.sops.templates."homepage.env".path ];

        settings = {
          title = domain;
          theme = "dark";
          color = "neutral";
          headerStyle = "clean";
          statusStyle = "dot";
          hideVersion = true;
          useEqualHeights = true;
          target = "_self";
          quicklaunch = {
            searchDescriptions = true;
            hideInternetSearch = true;
          };
          layout =
            genAttrs groups (_: {
              style = "row";
              columns = 4;
            })
            // {
              Links = {
                header = false;
                iconsOnly = true;
              };
            };
        };

        services = map (group: { ${group} = inGroup group; }) groups;

        bookmarks = [
          {
            Links = [
              {
                Cloudflare = [
                  {
                    icon = "cloudflare.svg";
                    href = "https://dash.cloudflare.com";
                  }
                ];
              }
              {
                Tailscale = [
                  {
                    icon = "tailscale.svg";
                    href = "https://console.tailscale.com";
                  }
                ];
              }
              {
                "FRITZ!Box" = [
                  {
                    icon = "fritzbox.svg";
                    href = "http://192.168.178.1";
                  }
                ];
              }
            ];
          }
        ];
      };

      sops.secrets = genAttrs (concatMap secretsOf (attrNames tiles)) (_: { });
      sops.templates."homepage.env".content = concatStrings (
        mapAttrsToList (
          name: service:
          concatStrings (
            map (field: "${envName name field}=${ph."dashboard/${name}/${field}"}\n") service.dashboard.secrets
          )
        ) tiles
      );

      axon.services.home.route.port = port;
    };
}
