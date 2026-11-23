# NVIDIA GPU load, memory and temperature: the node exporter can't read the proprietary driver,
# so a service leaves nvidia-smi's values in a textfile the node exporter serves.
{ lib, ... }:
{
  flake.modules.nixos.metrics =
    { config, pkgs, ... }:
    let
      inherit (config.axon) laptop nvidia;
      dir = "/run/prometheus-node-exporter-text";

      # while nvidia-smi fails (a driver updated before the reboot) the values are gone
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
    # not on laptops: polling keeps the GPU awake
    lib.mkIf (nvidia && !laptop) {
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
