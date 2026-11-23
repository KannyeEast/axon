# Looks through the tunnel every hour: its unit stays active when nothing gets through (the
# subscription ran out), and everything inside just stalls.
{ lib, ... }:
{
  flake.modules.nixos.vpn =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "server") {
      systemd.services.vpn-check = {
        description = "Check that the tunnel reaches the internet";
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          ExecStart = "${lib.getExe pkgs.curl} --silent --show-error --output /dev/null --max-time 20 --retry 3 --retry-all-errors https://1.1.1.1";
        };
      };

      systemd.timers.vpn-check = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "hourly";
          RandomizedDelaySec = "5m";
        };
      };

      axon.vpn.confined.vpn-check = { };
    };
}
