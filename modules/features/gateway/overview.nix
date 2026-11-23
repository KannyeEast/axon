# Homepage at home.<domain>: the start page, a tile per service with its status and numbers.
# Reach: tailnet, the gateway's login.
# By hand: add a tile's key with `just secrets` once its service has made it.
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
      description = "More links on the start page, name to url, icon and optionally group (Admin by default): what runs outside the cluster and no feature knows about.";
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

      envName = secret: "HOMEPAGE_VAR_${lib.toUpper (lib.replaceStrings [ "/" "-" ] [ "_" "_" ] secret)}";
      hasSecret = secret: lib.hasAttrByPath (lib.splitString "/" secret) config.axon.secrets;
      hasKeys = service: lib.all hasSecret (lib.attrValues service.dashboard.secrets);
      waiting = lib.attrNames (lib.filterAttrs (_: service: !hasKeys service) tiles);
      secrets = lib.unique (
        lib.concatMap (service: lib.attrValues service.dashboard.secrets) (
          lib.filter hasKeys (lib.attrValues tiles)
        )
      );

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
            label = "of ${size limits.${service.dashboard.space}}";
            query = ''axon_space_used_bytes{host="${host.name}",space="${service.dashboard.space}"}'';
            format.type = "bbytes";
          }
        ];
      };

      tile =
        service: name: instance:
        let
          widget = lib.defaultTo { } service.dashboard.widget // instance.widget or { };
          fromPrometheus = widget.type or null == "prometheusmetric";
          widgets =
            lib.optional (hasKeys service && widget != { } && (fromPrometheus -> prometheus != null)) (
              {
                url = if fromPrometheus then prometheus else service.route.internal;
              }
              // lib.defaultTo { } service.dashboard.widget
              // lib.mapAttrs (_: secret: "{{${envName secret}}}") service.dashboard.secrets
              // instance.widget or { }
            )
            # only on the tile that leads to the service itself
            ++ lib.optional (
              prometheus != null
              && service.dashboard.space != null
              && limits ? ${service.dashboard.space}
              && instance.link or null == null
            ) (spaceWidget service);
        in
        {
          ${name} = {
            href = lib.defaultTo service.route.url (instance.link or null);
            description = lib.defaultTo service.dashboard.description (instance.description or null);
            inherit (service.dashboard) icon;
            siteMonitor = service.route.internal + service.route.health;
          }
          // lib.optionalAttrs (widgets != [ ]) { inherit widgets; };
        };
      before =
        a: b:
        if a.service.dashboard.order != b.service.dashboard.order then
          a.service.dashboard.order < b.service.dashboard.order
        else
          a.service.dashboard.name < b.service.dashboard.name;
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

      # _start-page.css sets the tiles per row; this applies only without it
      columns = 4;
      first = [
        "Media"
        "Files"
        "Home"
        "Infrastructure"
      ];
      # groups of graphs, two per row so they get the width
      wide = [ "System" ];
      narrow = lib.subtractLists wide groups;
      ordered = lib.filter (group: lib.elem group narrow) first ++ lib.subtractLists first narrow;
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

      # Homepage keeps the order of the layout's entries and Nix sorts attribute sets
      layout = map (row: lib.listToAttrs [ (layoutOf row) ]) rows;

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
        # Next.js exits 143 on SIGTERM; without this every restart counts as a failure and alerts
        serviceConfig.SuccessExitStatus = [ 143 ];
      };

      axon.links = gateway.links;

      # Homepage shows only one of a services group and a link group of the same name
      assertions = [
        {
          assertion = lib.intersectLists linkGroups groups == [ ];
          message = "axon.links: group ${lib.concatStringsSep ", " (lib.intersectLists linkGroups groups)} is also a services group, so its links don't show; give the links another group";
        }
      ];

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
