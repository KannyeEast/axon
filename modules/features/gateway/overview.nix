# The start page (Homepage) at home.<domain>: a tile for every service with a dashboard entry,
# grouped, linked to its route and with a status dot; live numbers where it sets a widget, one
# tile per instance where it lists several. Widget credentials come from this host's
# secrets.json. Below the tiles, links to the admin pages of what runs outside the cluster.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    attrValues
    concatLists
    concatMap
    concatMapStrings
    concatStrings
    concatStringsSep
    elem
    filter
    filterAttrs
    genAttrs
    head
    length
    mapAttrs
    mapAttrsToList
    nameValuePair
    optionalAttrs
    replaceStrings
    sort
    subtractLists
    toJSON
    toUpper
    unique
    ;
in
{
  flake.modules.nixos.gateway =
    { config, pkgs, ... }:
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

      or' = value: fallback: if value != null then value else fallback;
      tile = service: name: instance: {
        ${name} = {
          href = or' (instance.link or null) "https://${service.route.subdomain}.${domain}";
          description = or' (instance.description or null) service.dashboard.description;
          icon = or' (instance.icon or null) service.dashboard.icon;
          siteMonitor = internal service.route + service.dashboard.monitor;
        }
        // optionalAttrs (service.dashboard.widget != null) {
          widget = {
            url = internal service.route;
          }
          // service.dashboard.widget
          // mapAttrs (_: secret: "{{${envName secret}}}") service.dashboard.secrets
          // instance.widget or { };
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

      # top to bottom on a grid of four; groups in one row share it, each with an equal part.
      # Groups not named here follow, alphabetically.
      rowsWanted = [
        [ "Media" ]
        [
          "Files"
          "Network"
        ]
        [ "System" ]
      ];
      columns = 4;
      rows = filter (row: row != [ ]) (
        map (filter (group: elem group groups)) rowsWanted
        ++ map (group: [ group ]) (subtractLists (concatLists rowsWanted) groups)
      );
      rowName = concatStringsSep " and ";
      grid = count: {
        style = "row";
        columns = count;
      };
      layoutOf =
        row:
        if length row == 1 then
          nameValuePair (head row) (grid columns)
        else
          nameValuePair (rowName row) (
            grid (length row) // { header = false; } // genAttrs row (_: grid (columns / length row))
          );

      # Homepage shows groups in the order of their layout entries, and Nix writes attribute sets
      # sorted, so the layout is written out by hand, one entry per line in row order
      layout = map layoutOf rows ++ [ (nameValuePair "Admin" (grid columns)) ];
      settingsFile = pkgs.writeText "settings.yaml" (
        concatStrings (
          mapAttrsToList (key: value: "${key}: ${toJSON value}\n") config.services.homepage-dashboard.settings
        )
        + "layout:\n"
        + concatMapStrings (entry: "  ${toJSON entry.name}: ${toJSON entry.value}\n") layout
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
          target = "_blank";
          quicklaunch = {
            searchDescriptions = true;
            hideInternetSearch = true;
          };
        };

        services = map (
          row:
          if length row == 1 then
            { ${head row} = inGroup (head row); }
          else
            { ${rowName row} = map (group: { ${group} = inGroup group; }) row; }
        ) rows;

        bookmarks = [
          {
            Admin = [
              {
                Cloudflare = [
                  {
                    icon = "cloudflare.svg";
                    href = "https://dash.cloudflare.com";
                    description = "dash.cloudflare.com ↗";
                  }
                ];
              }
              {
                Tailscale = [
                  {
                    icon = "tailscale.svg";
                    href = "https://console.tailscale.com";
                    description = "console.tailscale.com ↗";
                  }
                ];
              }
              {
                Mullvad = [
                  {
                    icon = "mullvad.svg";
                    href = "https://mullvad.net/en/account";
                    description = "mullvad.net ↗";
                  }
                ];
              }
              {
                "FRITZ!Box" = [
                  {
                    icon = "fritzbox.svg";
                    href = "http://192.168.178.1";
                    description = "192.168.178.1 ↗";
                  }
                ];
              }
            ];
          }
        ];
      };

      # Node exits with 143 on SIGTERM; without this every restart counts as a failure and mails
      systemd.services.homepage-dashboard.serviceConfig.SuccessExitStatus = [ 143 ];

      environment.etc."homepage-dashboard/settings.yaml".source = lib.mkForce settingsFile;

      sops.secrets = genAttrs secrets (_: { });
      sops.templates."homepage.env" = {
        content = concatStrings (map (secret: "${envName secret}=${ph.${secret}}\n") secrets);
        # a running Homepage keeps the variables it started with
        restartUnits = [ "homepage-dashboard.service" ];
      };

      axon.services.home.route.port = port;
    };
}
