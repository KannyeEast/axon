# The start page (Homepage) at home.<domain>: a tile for every service with a dashboard entry,
# grouped, linked to its route and with a status dot; live numbers where it sets a widget, one
# tile per instance where it lists several. Widget credentials come from this host's
# secrets.json; a service only makes its key once it runs, so until the key is there its tile
# shows no numbers. Below the tiles, axon.links and the [gateway] links of this host.
{ lib, ... }:
let
  inherit (lib)
    all
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
    hasAttrByPath
    head
    length
    mapAttrs
    mapAttrsToList
    match
    mkOption
    nameValuePair
    optional
    optionalAttrs
    replaceStrings
    sort
    splitString
    subtractLists
    toJSON
    toUpper
    types
    unique
    ;
in
{
  axon.schema.gateway = {
    options.gateway.links = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = { };
      example = {
        Router = {
          url = "http://192.168.1.1";
          icon = "router.svg";
        };
      };
      description = "More links on the start page, name to url and icon: what runs outside the cluster and no feature knows about.";
    };
  };

  flake.modules.nixos.gateway =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        domain
        gateway
        host
        links
        routes
        ;
      ph = config.sops.placeholder;

      port = 8082;

      tiles = filterAttrs (_: service: service.dashboard != null) routes;
      groups = unique (sort (a: b: a < b) (mapAttrsToList (_: service: service.dashboard.group) tiles));

      internal = route: "http://${route.endpoint}";
      # "dashboard/radarr/key" -> HOMEPAGE_VAR_DASHBOARD_RADARR_KEY
      envName = secret: "HOMEPAGE_VAR_${toUpper (replaceStrings [ "/" "-" ] [ "_" "_" ] secret)}";
      hasSecret = secret: hasAttrByPath (splitString "/" secret) config.axon.secrets;
      hasKeys = service: all hasSecret (attrValues service.dashboard.secrets);
      waiting = attrNames (filterAttrs (_: service: !hasKeys service) tiles);
      secrets = unique (
        concatMap (service: attrValues service.dashboard.secrets) (filter hasKeys (attrValues tiles))
      );

      or' = value: fallback: if value != null then value else fallback;
      tile = service: name: instance: {
        ${name} = {
          href = or' (instance.link or null) service.route.url;
          description = or' (instance.description or null) service.dashboard.description;
          icon = or' (instance.icon or null) service.dashboard.icon;
          siteMonitor = internal service.route + service.dashboard.monitor;
        }
        //
          optionalAttrs
            (hasKeys service && (service.dashboard.widget != null || instance.widget or { } != { }))
            {
              widget = {
                url = internal service.route;
              }
              // (or' service.dashboard.widget { })
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
        [ "Code" ]
        [ "System" ]
      ];
      columns = 4;
      # groups of graphs: two per row, so they get the width
      wide = [ "System" ];
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
          nameValuePair (head row) (grid (if elem (head row) wide then 2 else columns))
        else
          nameValuePair (rowName row) (
            grid (length row) // { header = false; } // genAttrs row (_: grid (columns / length row))
          );

      # Homepage shows groups in the order of their layout entries, and Nix writes attribute sets
      # sorted, so the layout is written out by hand, one entry per line in row order
      layout = map layoutOf rows;
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
        allowedHosts = routes.home.route.host;
        environmentFiles = [ config.sops.templates."homepage.env".path ];

        # the reload button, which Homepage puts in the footer, stays in the top right corner
        customCSS = ''
          #revalidate {
            position: fixed;
            top: 1.5rem;
            right: 1.5rem;
            z-index: 20;
          }
        '';

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

        bookmarks = optional (links != { }) {
          Admin = mapAttrsToList (name: link: {
            ${name} = [
              {
                inherit (link) icon;
                href = link.url;
                description = "${head (match "[a-z]+://([^/]+).*" link.url)} ↗";
              }
            ];
          }) links;
        };
      };

      axon.links = gateway.links;

      warnings =
        optional (waiting != [ ])
          "hosts/${host.name}/secrets.json: no widget key yet for ${concatStringsSep ", " waiting}, so those tiles show no numbers; add the keys with `just secrets ${host.name}`";

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
