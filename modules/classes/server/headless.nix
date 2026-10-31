# The server class: unattended, reachable, and quiet about it.
{
  flake.modules.nixos.server = {
    documentation.enable = false;
    boot.loader.timeout = 1;

    services.smartd = {
      enable = true;
      autodetect = true;
    };

    # come back by itself after a power cut
    systemd.settings.Manager.RuntimeWatchdogSec = "30s";
  };
}
