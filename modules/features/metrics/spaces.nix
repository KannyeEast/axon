# Use and limit of each volume or space in [limits], from its btrfs qgroup, into a textfile the
# node exporter serves; a subvolume or qgroup that doesn't exist yet is left out.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, pkgs, ... }:
    let
      inherit (config.axon) limits spaces volumes;
      dir = "/run/prometheus-node-exporter-text";

      paths =
        volumes // lib.mapAttrs (_: space: space.path) (lib.filterAttrs (_: space: space.onVolume) spaces);
      limited = lib.filterAttrs (name: _: limits ? ${name}) paths;

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
            lib.mapAttrsToList (name: path: ''
              report ${name} ${path}
            '') limited
          )}
          } >${dir}/spaces.prom.tmp
          mv ${dir}/spaces.prom.tmp ${dir}/spaces.prom
        '';
      };
    in
    lib.mkIf (limited != { }) {
      systemd.services.space-metrics = {
        description = "Use and limit of the spaces in [limits] for the node exporter";
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
