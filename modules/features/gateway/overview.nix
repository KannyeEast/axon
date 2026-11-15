# The start page (Homepage) at home.<domain>: a tile for every service with a dashboard entry,
# grouped on a grid of tiles of one width, linked to its route and with a status dot; live
# numbers where it sets a widget, amber where its widget's highlight marks one, one tile per
# instance where it lists several. Widget keys come from secrets.json, and a service makes its
# key only once it runs, so its tile shows no numbers until then. Below the tiles, axon.links and
# this host's [gateway] links. _start-page.js adds a search, group chips, a compact view and a
# bar listing what is marked amber.
{ lib, ... }:
let
  inherit (lib) mkOption types;
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
      description = "More links on the start page, name to url, icon and optionally group (Infrastructure by default): what runs outside the cluster and no feature knows about.";
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

      tiles = lib.filterAttrs (_: service: service.dashboard != null) routes;
      groups = lib.unique (
        lib.sort (a: b: a < b) (lib.mapAttrsToList (_: service: service.dashboard.group) tiles)
      );
      linkGroups = lib.unique (lib.sort (a: b: a < b) (lib.mapAttrsToList (_: link: link.group) links));

      # "dashboard/radarr/key" -> HOMEPAGE_VAR_DASHBOARD_RADARR_KEY
      envName = secret: "HOMEPAGE_VAR_${lib.toUpper (lib.replaceStrings [ "/" "-" ] [ "_" "_" ] secret)}";
      hasSecret = secret: lib.hasAttrByPath (lib.splitString "/" secret) config.axon.secrets;
      hasKeys = service: lib.all hasSecret (lib.attrValues service.dashboard.secrets);
      waiting = lib.attrNames (lib.filterAttrs (_: service: !hasKeys service) tiles);
      secrets = lib.unique (
        lib.concatMap (service: lib.attrValues service.dashboard.secrets) (
          lib.filter hasKeys (lib.attrValues tiles)
        )
      );

      tile = service: name: instance: {
        ${name} = {
          href = lib.defaultTo service.route.url (instance.link or null);
          description = lib.defaultTo service.dashboard.description (instance.description or null);
          inherit (service.dashboard) icon;
          siteMonitor = service.route.internal + service.dashboard.monitor;
        }
        //
          lib.optionalAttrs
            (hasKeys service && (service.dashboard.widget != null || instance.widget or { } != { }))
            {
              widget = {
                url = service.route.internal;
              }
              // lib.defaultTo { } service.dashboard.widget
              // lib.mapAttrs (_: secret: "{{${envName secret}}}") service.dashboard.secrets
              // instance.widget or { };
            };
      };
      tilesOf =
        service:
        if service.dashboard.instances == { } then
          [ (tile service service.dashboard.name { }) ]
        else
          lib.mapAttrsToList (tile service) service.dashboard.instances;
      before =
        a: b:
        if a.dashboard.order != b.dashboard.order then
          a.dashboard.order < b.dashboard.order
        else
          a.dashboard.name < b.dashboard.name;
      inGroup =
        group:
        lib.concatMap tilesOf (
          lib.sort before (
            lib.attrValues (lib.filterAttrs (_: service: service.dashboard.group == group) tiles)
          )
        );

      # Every tile has the same width on a grid of four: a group takes a column per tile (all four
      # and wraps when it has more) and shares a row with the groups before it while they fit.
      # The groups named here come first, the rest alphabetically
      columns = 4;
      first = [
        "Media"
        "Files"
        "Home"
        "Network"
        "Code"
      ];
      # groups of graphs: last, two per row, so they get the width
      wide = [ "System" ];
      span = group: lib.min columns (lib.length (inGroup group));
      narrow = lib.subtractLists wide groups;
      used = row: lib.foldl' (sum: group: sum + span group) 0 row;
      rows =
        lib.foldl' (
          rows: group:
          if rows != [ ] && used (lib.last rows) + span group <= columns then
            lib.init rows ++ [ (lib.last rows ++ [ group ]) ]
          else
            rows ++ [ [ group ] ]
        ) [ ] (lib.filter (group: lib.elem group narrow) first ++ lib.subtractLists first narrow)
        ++ map (group: [ group ]) (lib.intersectLists wide groups);
      rowName = lib.concatStringsSep " and ";
      grid = count: {
        style = "row";
        columns = count;
      };
      layoutOf =
        row:
        if lib.length row == 1 then
          lib.nameValuePair (lib.head row) (grid (if lib.elem (lib.head row) wide then 2 else columns))
        else
          lib.nameValuePair (rowName row) (
            grid columns
            // {
              header = false;
            }
            // lib.genAttrs row (group: grid (span group))
          );
      # Homepage gives each group of a shared row an equal part of it; spanning a column per tile
      # keeps the tiles one width (two columns from md, all from lg, as Homepage's grids have)
      spans = ''
        @media (min-width: 48rem) {
          .subgroup:has(.services-list.md\:grid-cols-2) { grid-column: span 2; }
        }
        @media (min-width: 64rem) {
      ''
      + lib.concatMapStrings (
        count:
        "  .subgroup:has(.services-list.lg\\:grid-cols-${toString count}) { grid-column: span ${toString count}; }\n"
      ) (lib.range 2 columns)
      + "}\n";

      # Homepage shows groups in the order of their layout entries, and Nix writes attribute sets
      # sorted, so the layout is written out by hand, one entry per line in row order
      layout = map layoutOf rows;
      page = {
        customCSS = lib.readFile ./_start-page.css + spans;
        customJS = lib.readFile ./_start-page.js;

        settings = {
          title = domain;
          theme = "dark";
          color = "neutral";
          headerStyle = "clean";
          statusStyle = "dot";
          hideVersion = true;
          useEqualHeights = true;
        };

        services = map (
          row:
          if lib.length row == 1 then
            { ${lib.head row} = inGroup (lib.head row); }
          else
            { ${rowName row} = map (group: { ${group} = inGroup group; }) row; }
        ) rows;

        # one list per link group, the groups and the links in each alphabetical
        bookmarks = map (group: {
          ${group} = lib.mapAttrsToList (name: link: {
            ${name} = [
              {
                inherit (link) icon;
                href = link.url;
                description = "${lib.head (lib.match "[a-z]+://([^/]+).*" link.url)} ↗";
              }
            ];
          }) (lib.filterAttrs (_: link: link.group == group) links);
        }) linkGroups;
      };

      settingsFile = pkgs.writeText "settings.yaml" (
        lib.concatStrings (lib.mapAttrsToList (key: value: "${key}: ${lib.toJSON value}\n") page.settings)
        + "layout:\n"
        + lib.concatMapStrings (entry: "  ${lib.toJSON entry.name}: ${lib.toJSON entry.value}\n") layout
      );

      yaml = pkgs.formats.yaml { };
      # copies, not links: the container doesn't see the store. Homepage fills in a file that's
      # missing, which the read-only mount refuses, so every file it reads is here
      files = pkgs.runCommandLocal "homepage-config" { } (
        "mkdir $out\n"
        + lib.concatStrings (
          lib.mapAttrsToList (name: path: "cp ${path} $out/${name}\n") {
            "settings.yaml" = settingsFile;
            "services.yaml" = yaml.generate "services.yaml" page.services;
            "bookmarks.yaml" = yaml.generate "bookmarks.yaml" page.bookmarks;
            "widgets.yaml" = yaml.generate "widgets.yaml" [ ];
            "docker.yaml" = yaml.generate "docker.yaml" { };
            "kubernetes.yaml" = yaml.generate "kubernetes.yaml" { };
            "proxmox.yaml" = yaml.generate "proxmox.yaml" { };
            "custom.css" = pkgs.writeText "custom.css" page.customCSS;
            "custom.js" = pkgs.writeText "custom.js" page.customJS;
          }
        )
      );
    in
    {
      virtualisation.oci-containers.containers.homepage = {
        image = "ghcr.io/gethomepage/homepage:v2.8.0@sha256:019d8f063a7299e7c1c51ee4a70b692291809af3244894fbec2c2ac7d1f71b18";
        # widgets ask the services on 127.0.0.1, which only the host's network reaches
        networks = [ "host" ];
        environment = {
          HOSTNAME = "127.0.0.1";
          PORT = toString port;
          HOMEPAGE_ALLOWED_HOSTS = routes.home.route.host;
          LOG_TARGETS = "stdout";
        };
        environmentFiles = [ config.sops.templates."homepage.env".path ];
        volumes = [ "${files}:/app/config:ro" ];
      };

      axon.links = gateway.links;

      warnings =
        lib.optional (waiting != [ ])
          "hosts/${host.name}/secrets.json: no widget key yet for ${lib.concatStringsSep ", " waiting}, so those tiles show no numbers; add the keys with `just secrets ${host.name}`";

      # Node exits with 143 on SIGTERM; without this every restart counts as a failure and mails
      systemd.services.docker-homepage.serviceConfig.SuccessExitStatus = [ 143 ];

      sops.secrets = lib.genAttrs secrets (_: { });
      sops.templates."homepage.env" = {
        content = lib.concatStrings (map (secret: "${envName secret}=${ph.${secret}}\n") secrets);
        # a running Homepage keeps the variables it started with
        restartUnits = [ "docker-homepage.service" ];
      };

      axon.services.home.route.port = port;
    };
}
