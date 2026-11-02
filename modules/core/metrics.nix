# The Beszel agent: CPU, memory, network, temperatures, SMART and the data disks, for the
# cluster's hub (the monitoring feature). Runs once the hub's host.toml carries its key; the hub
# connects to it over the tailnet.
{ lib, ... }:
let
  inherit (lib)
    attrValues
    concatStringsSep
    elem
    filterAttrs
    head
    mapAttrsToList
    mkIf
    optionalAttrs
    ;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster disk;
      hubs = attrValues (filterAttrs (_: data: elem "monitoring" data.host.features) cluster.hosts);
      key = if hubs == [ ] then null else (head hubs).monitoring.key;

      # "/server/data__bulk": the first mount of each data disk, shown under the disk's label
      filesystems = mapAttrsToList (label: fs: "${head (attrValues fs.mounts)}__${label}") (
        filterAttrs (label: fs: label != "boot" && fs.mounts or { } != { }) disk
      );
    in
    mkIf (key != null) {
      services.beszel.agent = {
        enable = true;
        smartmon.enable = true;
        environment = {
          KEY = key;
        }
        // optionalAttrs (filesystems != [ ]) {
          EXTRA_FILESYSTEMS = concatStringsSep "," filesystems;
        };
      };

      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
        45876
      ];

      axon.persist.directories = [
        {
          directory = "/var/lib/private/beszel-agent";
          mode = "0700";
        }
      ];
    };
}
