# The start page (Homepage) at home.<domain>: a tile for every service with a dashboard entry,
# grouped, linked to its route and with a status dot; live numbers where it sets a widget.
# Widget credentials come from secrets.json dashboard/<service>/<field>. Services that mark
# calendar = true put their releases into the Calendar tab.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatMap
    concatStrings
    filter
    filterAttrs
    genAttrs
    head
    mapAttrsToList
    optional
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
      inherit (config.axon) cluster services disk;
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

      releases = filterAttrs (_: service: service.dashboard.calendar) tiles;
      calendar = {
        Calendar = [
          {
            Releases.widget = {
              type = "calendar";
              view = "monthly";
              showTime = true;
              integrations = mapAttrsToList (_: service: {
                type = service.dashboard.widget.type;
                service_group = service.dashboard.group;
                service_name = service.dashboard.name;
                baseUrl = "https://${service.route.subdomain}.${domain}";
              }) releases;
            };
          }
        ];
      };

      # one bar per filesystem: the first mount of every data disk
      filesystems = [
        "/"
      ]
      ++ concatMap (
        label:
        optional (disk.${label} ? mounts && disk.${label}.mounts != { }) (
          head (lib.attrValues disk.${label}.mounts)
        )
      ) (filter (label: label != "boot") (attrNames disk));
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
              tab = "Home";
              style = "row";
              columns = 4;
            })
            // optionalAttrs (releases != { }) { Calendar.tab = "Calendar"; };
        };

        services = map (group: { ${group} = inGroup group; }) groups ++ optional (releases != { }) calendar;

        widgets = [
          {
            resources = {
              cpu = true;
              memory = true;
              cputemp = true;
              uptime = true;
              disk = filesystems;
              units = "metric";
            };
          }
          {
            datetime = {
              text_size = "md";
              format = {
                dateStyle = "medium";
                timeStyle = "short";
                hour12 = false;
              };
            };
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
