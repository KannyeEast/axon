# exportarr for Sonarr, Radarr, Prowlarr and SABnzbd's queue, each with <name>/api-key, while
# this host lists metrics and a host runs monitoring; they answer on the overlay only.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        hasSecret
        host
        hostsWith
        routes
        services
        ;
      secret = name: services.${name}.apiKey;
      hasKey = name: hasSecret (secret name);
      scraped = lib.elem "metrics" host.features && hostsWith "monitoring" != { };

      # monitoring/metrics.nix scrapes these same ports
      arr = lib.optionalAttrs (config.axon.volumes ? media) {
        sonarr = 9707;
        radarr = 9708;
        prowlarr = 9710;
      };
      keyed = lib.filterAttrs (name: _: hasKey name) arr;
      sabnzbd = 9387;
      missing = lib.filter (name: !hasKey name) (lib.attrNames arr ++ [ "usenet" ]);
    in
    lib.mkIf scraped (
      lib.mkMerge [
        {
          services.prometheus.exporters = lib.mapAttrs' (
            name: port:
            lib.nameValuePair "exportarr-${name}" {
              enable = true;
              inherit port;
              url = routes.${name}.route.internal;
              apiKeyFile = config.sops.secrets.${secret name}.path;
              # at info it logs every API call it makes
              environment.LOG_LEVEL = "warn";
            }
          ) keyed;
          sops.secrets = lib.mapAttrs' (
            name: _:
            lib.nameValuePair (secret name) {
              restartUnits = [ "prometheus-exportarr-${name}-exporter.service" ];
            }
          ) keyed;
          axon.overlay.tcpPorts = lib.attrValues keyed;
          warnings =
            lib.optional (missing != [ ])
              "hosts/${host.name}/secrets.json: no ${
                lib.concatMapStringsSep ", " secret missing
              }, so those exporters are off; add them with `just secrets ${host.name}`";
        }

        (lib.mkIf (hasKey "usenet") {
          # nixpkgs has no exportarr module for SABnzbd: the unit is written out as one would
          systemd.services.exportarr-sabnzbd = {
            description = "Prometheus exporter for SABnzbd";
            wantedBy = [ "multi-user.target" ];
            environment = {
              PORT = toString sabnzbd;
              URL = routes.usenet.route.internal;
              API_KEY_FILE = "%d/api-key";
              LOG_LEVEL = "warn";
            };
            after = [ "network.target" ];
            serviceConfig = {
              DynamicUser = true;
              Restart = "always";
              LoadCredential = "api-key:${config.sops.secrets.${secret "usenet"}.path}";
              ExecStart = "${lib.getExe pkgs.exportarr} sabnzbd";
              CapabilityBoundingSet = [ "" ];
              DeviceAllow = [ "" ];
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              NoNewPrivileges = true;
              PrivateDevices = true;
              PrivateTmp = true;
              ProcSubset = "pid";
              ProtectClock = true;
              ProtectControlGroups = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectProc = "invisible";
              ProtectSystem = "strict";
              RemoveIPC = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
              ];
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              SystemCallArchitectures = "native";
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
              ];
              UMask = "0077";
              WorkingDirectory = "/tmp";
            };
          };
          sops.secrets.${secret "usenet"}.restartUnits = [ "exportarr-sabnzbd.service" ];
          axon.overlay.tcpPorts = [ sabnzbd ];
        })
      ]
    );
}
