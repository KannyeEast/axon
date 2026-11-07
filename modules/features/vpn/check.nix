# Looks through the tunnel every hour. Its unit stays active even when nothing gets through, say
# once the subscription has run out, and everything inside just stalls. A failure here is mailed
# like any other.
{ lib, ... }:
{
  flake.modules.nixos.vpn =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "server") {
      axon.vpn.confined.vpn-check = { };

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
    };
}
