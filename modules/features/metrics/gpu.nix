# NVIDIA GPU load, memory and temperature for Prometheus. The node exporter can't read the
# proprietary driver, so a small service asks nvidia-smi every 15 seconds and leaves the values in
# a textfile the node exporter serves along with its own. Not on laptops, where asking keeps the
# GPU awake. When nvidia-smi fails (a driver update before the reboot), the values just go.
# nixpkgs' nvidia-gpu exporter would need a scrape target of its own on every GPU host, and the
# host running Prometheus can't tell which hosts have one; the node exporter is on all of them.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, pkgs, ... }:
    let
      dir = "/run/prometheus-node-exporter-text";
      inherit (config.axon) laptop nvidia;

      poll = pkgs.writeShellApplication {
        name = "gpu-metrics";
        runtimeInputs = [ config.hardware.nvidia.package.bin ];
        text = ''
          while true; do
            if out=$(nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits); then
              while IFS=', ' read -r gpu load used total temp; do
                echo "nvidia_gpu_utilization_percent{gpu=\"$gpu\"} $load"
                echo "nvidia_gpu_memory_used_bytes{gpu=\"$gpu\"} $((used * 1048576))"
                echo "nvidia_gpu_memory_total_bytes{gpu=\"$gpu\"} $((total * 1048576))"
                echo "nvidia_gpu_temperature_celsius{gpu=\"$gpu\"} $temp"
              done <<<"$out" >${dir}/gpu.prom.tmp
              mv ${dir}/gpu.prom.tmp ${dir}/gpu.prom
            else
              rm -f ${dir}/gpu.prom
            fi
            sleep 15
          done
        '';
      };
    in
    lib.mkIf (nvidia && !laptop) {
      services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
      systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];

      systemd.services.gpu-metrics = {
        description = "NVIDIA GPU values for the node exporter";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = lib.getExe poll;
          Restart = "on-failure";
        };
      };
    };
}
