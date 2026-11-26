# Use and limit of each space on a data disk, from its btrfs qgroup, into a textfile the node
# exporter serves; a space without a limit reports its use only, one not made yet nothing.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, pkgs, ... }:
    let
      dir = "/run/prometheus-node-exporter-text";

      placed = lib.filterAttrs (_: space: space.disk != null) config.axon.spaces;

      # --format json: {"qgroup-show": [{"referenced": <bytes>, "max_referenced": <bytes> or "none", …}]}
      lines = pkgs.writeText "space-metrics.jq" ''
        .["qgroup-show"][]
        | "axon_space_used_bytes{space=\"\($space)\"} \(.referenced)",
          (.max_referenced | numbers | "axon_space_limit_bytes{space=\"\($space)\"} \(.)")
      '';

      collect = pkgs.writeShellApplication {
        name = "space-metrics";
        runtimeInputs = [
          pkgs.btrfs-progs
          pkgs.jq
        ];
        text = ''
          report() {
            # a subvolume's top folder is always inode 256
            [ "$(stat -c %i "$2" 2>/dev/null)" = 256 ] || return 0
            # -f: the qgroup of this subvolume alone; fails while quotas are off
            json=$(btrfs --format json qgroup show -f "$2" 2>/dev/null) || return 0
            jq -r --arg space "$1" -f ${lines} <<<"$json"
          }

          {
          ${lib.concatStrings (
            lib.mapAttrsToList (name: space: ''
              report ${name} ${space.path}
            '') placed
          )}
          } >${dir}/spaces.prom.tmp
          mv ${dir}/spaces.prom.tmp ${dir}/spaces.prom
        '';
      };
    in
    lib.mkIf (placed != { }) {
      systemd.services.space-metrics = {
        description = "Use and limit of the spaces on data disks for the node exporter";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe collect;
        };
      };

      systemd.timers.space-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "5min";
        };
      };
    };
}
