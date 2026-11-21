# Exporters for the download stack, while this host lists metrics and a host runs monitoring, which
# scrapes them on the ports written out here and in monitoring/metrics.nix: exportarr for Sonarr,
# Radarr and Prowlarr, and SABnzbd's queue, each with its key dashboard/<name>/key. They answer on
# the overlay only.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, ... }:
    let
      inherit (config.axon) cluster host routes;
      secret = name: "dashboard/${name}/key";
      hasKey = name: lib.hasAttrByPath (lib.splitString "/" (secret name)) config.axon.secrets;
      scraped =
        lib.elem "metrics" host.features
        && lib.any (data: lib.elem "monitoring" data.host.features) (lib.attrValues cluster.hosts);

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
          services.prometheus.exporters.sabnzbd = {
            enable = true;
            port = sabnzbd;
            servers = [
              {
                baseUrl = routes.usenet.route.internal;
                apiKeyFile = config.sops.secrets.${secret "usenet"}.path;
              }
            ];
          };
          sops.secrets.${secret "usenet"}.restartUnits = [ "prometheus-sabnzbd-exporter.service" ];
          axon.overlay.tcpPorts = [ sabnzbd ];
        })
      ]
    );
}
