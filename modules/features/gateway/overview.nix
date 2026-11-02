# The start page (Homepage) at home.<domain>: a tile for every service with a dashboard entry,
# grouped, linked to its route and with a status dot; live numbers where it sets a widget, one
# tile per instance where it lists several. Widget credentials come from this host's
# secrets.json. Below the tiles, links to the admin pages of what runs outside the cluster.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    concatStrings
    filterAttrs
    genAttrs
    head
    mapAttrs
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
      # "dashboard/radarr/key" -> HOMEPAGE_VAR_DASHBOARD_RADARR_KEY
      envName = secret: "HOMEPAGE_VAR_${toUpper (replaceStrings [ "/" "-" ] [ "_" "_" ] secret)}";
      secrets = unique (concatMap (service: attrValues service.dashboard.secrets) (attrValues tiles));

      tile = service: name: instance: {
        ${name} = {
          href = "https://${service.route.subdomain}.${domain}";
          inherit (service.dashboard) description icon;
          siteMonitor = internal service.route + service.dashboard.monitor;
        }
        // optionalAttrs (service.dashboard.widget != null) {
          widget = {
            url = internal service.route;
          }
          // service.dashboard.widget
          // mapAttrs (_: secret: "{{${envName secret}}}") service.dashboard.secrets
          // instance;
        };
      };
      tilesOf =
        service:
        if service.dashboard.instances == { } then
          [ (tile service service.dashboard.name { }) ]
        else
          mapAttrsToList (tile service) service.dashboard.instances;
      inGroup =
        group:
        sort (a: b: head (attrNames a) < head (attrNames b)) (
          concatMap tilesOf (attrValues (filterAttrs (_: service: service.dashboard.group == group) tiles))
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
          layout = genAttrs groups (_: {
            style = "row";
            columns = 4;
          });
        };

        services = map (group: { ${group} = inGroup group; }) groups;

        bookmarks = [
          {
            Admin = [
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
                Mullvad = [
                  {
                    icon = "mullvad.svg";
                    href = "https://mullvad.net/en/account";
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

      sops.secrets = genAttrs secrets (_: { });
      sops.templates."homepage.env".content = concatStrings (
        map (secret: "${envName secret}=${ph.${secret}}\n") secrets
      );

      axon.services.home.route.port = port;
    };
}
