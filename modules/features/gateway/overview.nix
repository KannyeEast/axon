# The start page (Homepage) at home.<domain>: a tile per service with a dashboard entry, grouped,
# linked to its route, with a status dot and, where it sets a widget, live numbers (amber where the
# widget's highlight marks one). A service makes its widget key only once it runs, so its tile
# shows no numbers until the key is in secrets.json. A service whose space [limits] caps shows its
# use against that limit, from Prometheus (metrics/spaces.nix). Below the tiles, axon.links and [gateway]
# links; _start-page.js adds the header, attention bar, group chips and the tiles' logs links.
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
    { config, ... }:
    let
      inherit (config.axon)
        cluster
        gateway
        host
        limits
        links
        routes
        ;
      ph = config.sops.placeholder;

      port = 8082;

      tiles = lib.filterAttrs (_: service: service.dashboard != null) routes;
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

      # Prometheus (its default port) on a monitoring host, this host's own where it has one; the
      # values exist only while this host lists metrics
      monitors = lib.attrNames (
        lib.filterAttrs (_: data: lib.elem "monitoring" data.host.features) cluster.hosts
      );
      prometheus =
        if !lib.elem "metrics" host.features || monitors == [ ] then
          null
        else if lib.elem host.name monitors then
          "http://127.0.0.1:9090"
        else
          "http://${lib.head monitors}:9090";
      # "7T" -> "7 TiB"
      size =
        limit:
        let
          parts = lib.match "([0-9]+)([KMGTP]?)" limit;
          unit = lib.elemAt parts 1;
        in
        "${lib.head parts} ${if unit == "" then "B" else "${unit}iB"}";
      spaceWidget = service: {
        type = "prometheusmetric";
        url = prometheus;
        metrics = [
          {
            label = "of ${size limits.${service.space}}";
            query = ''axon_space_used_bytes{host="${host.name}",space="${service.space}"}'';
            format.type = "bbytes";
          }
        ];
      };

      tile =
        service: name: instance:
        let
          widgets =
            lib.optional
              (hasKeys service && (service.dashboard.widget != null || instance.widget or { } != { }))
              (
                {
                  url = service.route.internal;
                }
                // lib.defaultTo { } service.dashboard.widget
                // lib.mapAttrs (_: secret: "{{${envName secret}}}") service.dashboard.secrets
                // instance.widget or { }
              )
            # on the tile that leads to the service itself, not on those linking elsewhere
            ++ lib.optional (
              prometheus != null
              && service.space != null
              && limits ? ${service.space}
              && instance.link or null == null
            ) (spaceWidget service);
        in
        {
          ${name} = {
            href = lib.defaultTo service.route.url (instance.link or null);
            description = lib.defaultTo service.dashboard.description (instance.description or null);
            inherit (service.dashboard) icon;
            siteMonitor = service.route.internal + service.dashboard.monitor;
          }
          // lib.optionalAttrs (widgets != [ ]) { inherit widgets; };
        };
      before =
        a: b:
        if a.service.dashboard.order != b.service.dashboard.order then
          a.service.dashboard.order < b.service.dashboard.order
        else
          a.service.dashboard.name < b.service.dashboard.name;
      # every tile with its service and group, in order; an instance may sit in a group of its own
      entries = lib.concatMap (
        { name, service }:
        map
          (instance: {
            inherit name;
            group = lib.defaultTo service.dashboard.group (instance.value.group or null);
            tile = tile service instance.name instance.value;
          })
          (
            if service.dashboard.instances == { } then
              [ (lib.nameValuePair service.dashboard.name { }) ]
            else
              lib.attrsToList service.dashboard.instances
          )
      ) (lib.sort before (lib.mapAttrsToList (name: service: { inherit name service; }) tiles));
      groups = lib.unique (lib.sort (a: b: a < b) (map (entry: entry.group) entries));
      inGroup = group: map (entry: entry.tile) (lib.filter (entry: entry.group == group) entries);

      # Each group has its own rows, except groups of one tile: those share a row at the bottom,
      # above the groups of graphs. The groups named here come first, the rest alphabetically.
      # _start-page.css sets how many tiles fit a row; Homepage's columns only apply without it
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
      narrow = lib.subtractLists wide groups;
      ordered = lib.filter (group: lib.elem group narrow) first ++ lib.subtractLists first narrow;
      # for the subtitle: tiles outside the graph groups, and the machines this repository builds
      serviceCount = lib.length (lib.concatMap inGroup narrow);
      hostCount = lib.length (lib.attrNames config.axon.cluster.hosts);
      single = group: lib.length (inGroup group) == 1;
      singles = lib.filter single ordered;
      rows =
        map (group: [ group ]) (lib.filter (group: !single group) ordered)
        ++ lib.optional (singles != [ ]) singles
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
            // lib.genAttrs row (_: grid 1)
          );

      # Homepage shows groups in the order of their layout entries, and Nix writes attribute sets
      # sorted, so the layout is a list of one-entry sets, which Homepage reads in order
      layout = map (row: lib.listToAttrs [ (layoutOf row) ]) rows;

      # tile name -> its service in Grafana's Logs Drilldown (service_name from metrics/logs.nix),
      # for every tile outside the graph groups, while this host ships its logs and Grafana is routed here
      logs = lib.optionalAttrs (lib.elem "metrics" host.features && routes ? grafana) (
        lib.mergeAttrsList (
          map (
            entry:
            lib.mapAttrs (
              _: _:
              "${routes.grafana.route.url}/a/grafana-lokiexplore-app/explore/service/${entry.name}/logs?var-filters=service_name%7C%3D%7C${entry.name}"
            ) entry.tile
          ) (lib.filter (entry: lib.elem entry.group narrow) entries)
        )
      );
    in
    {
      services.homepage-dashboard = {
        enable = true;
        listenPort = port;
        allowedHosts = routes.home.route.host;
        environmentFiles = [ config.sops.templates."homepage.env".path ];

        customCSS = lib.readFile ./_start-page.css;
        customJS =
          lib.optionalString (logs != { }) ''
            window.startPageLogs = ${lib.toJSON logs};
          ''
          + lib.readFile ./_start-page.js;

        settings = {
          title = "Homelab";
          # the subtitle under the title in _start-page.js's header
          description = "${toString serviceCount} services, ${toString hostCount} host${
            lib.optionalString (hostCount != 1) "s"
          }";
          theme = "dark";
          color = "neutral";
          statusStyle = "dot";
          hideVersion = true;
          fullWidth = true;
          useEqualHeights = true;
          inherit layout;
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

      systemd.services.homepage-dashboard = {
        # Next.js listens on every address unless told otherwise
        environment.HOSTNAME = "127.0.0.1";
        # Next.js exits with 143 on SIGTERM; without this every restart counts as a failure and mails
        serviceConfig.SuccessExitStatus = [ 143 ];
      };

      axon.links = gateway.links;

      warnings =
        lib.optional (waiting != [ ])
          "hosts/${host.name}/secrets.json: no widget key yet for ${lib.concatStringsSep ", " waiting}, so those tiles show no numbers; add the keys with `just secrets ${host.name}`";

      sops.secrets = lib.genAttrs secrets (_: { });
      sops.templates."homepage.env" = {
        content = lib.concatStrings (map (secret: "${envName secret}=${ph.${secret}}\n") secrets);
        # a running Homepage keeps the variables it started with
        restartUnits = [ "homepage-dashboard.service" ];
      };

      axon.services.home = {
        units = [ "homepage-dashboard" ];
        route.port = port;
      };
    };
}
