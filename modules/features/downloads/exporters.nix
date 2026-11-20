# Exporters for the download stack, while this host lists metrics and a host runs monitoring, which
# scrapes them on the ports written out here and in monitoring/metrics.nix: exportarr for Sonarr,
# Radarr and Prowlarr, reading each app's API key from its own config.xml, and SABnzbd's queue with
# its widget key, dashboard/usenet/key. They answer on the overlay only.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      inherit (config.axon) cluster host routes;
      key = "dashboard/usenet/key";
      hasKey = lib.hasAttrByPath (lib.splitString "/" key) config.axon.secrets;
      scraped =
        lib.elem "metrics" host.features
        && lib.any (data: lib.elem "monitoring" data.host.features) (lib.attrValues cluster.hosts);

      arr = {
        sonarr = {
          port = 9707;
          inherit (config.services.sonarr) dataDir;
        };
        radarr = {
          port = 9708;
          inherit (config.services.radarr) dataDir;
        };
        prowlarr = {
          port = 9710;
          inherit (config.services.prowlarr) dataDir;
        };
      };
      sabnzbd = 9387;
    in
    lib.mkIf scraped (
      lib.mkMerge [
        (lib.mkIf (config.axon.volumes ? media) {
          services.prometheus.exporters = lib.mapAttrs' (
            name: app:
            lib.nameValuePair "exportarr-${name}" {
              enable = true;
              inherit (app) port;
              url = routes.${name}.route.internal;
              # key, port and URL base from config.xml
              environment.CONFIG = "%d/config";
            }
          ) arr;

          systemd.services = lib.mapAttrs' (
            name: app:
            lib.nameValuePair "prometheus-exportarr-${name}-exporter" {
              after = [ "${name}.service" ];
              serviceConfig = {
                # replaces the module's empty LoadCredential, which it sets without an apiKeyFile
                LoadCredential = lib.mkForce "config:${app.dataDir}/config.xml";
                # config.xml appears only once the app has started: retry until then instead of
                # failing for good after five quick tries
                RestartSec = "30s";
              };
            }
          ) arr;

          axon.overlay.tcpPorts = lib.mapAttrsToList (_: app: app.port) arr;
        })

        (lib.mkIf hasKey {
          services.prometheus.exporters.sabnzbd = {
            enable = true;
            port = sabnzbd;
            servers = [
              {
                baseUrl = routes.usenet.route.internal;
                apiKeyFile = config.sops.secrets.${key}.path;
              }
            ];
          };
          sops.secrets.${key} = { };
          axon.overlay.tcpPorts = [ sabnzbd ];
        })

        (lib.mkIf (!hasKey) {
          warnings = [
            "hosts/${host.name}/secrets.json: no ${key}, so SABnzbd's exporter doesn't run: its queue isn't watched and Prometheus reports the exporter down; add SABnzbd's API key with `just secrets ${host.name}`"
          ];
        })
      ]
    );
}
