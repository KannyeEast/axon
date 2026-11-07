# NetworkManager, with its connections kept across reboots. Networks are joined once
# (nmtui, nmcli or the desktop) and stay; nothing about them is declared here.
{
  flake.modules.nixos.core =
    { config, ... }:
    {
      networking.hostName = config.axon.host.name;
      networking.networkmanager.enable = true;
      networking.modemmanager.enable = false;

      axon.persist.directories = [
        "/var/lib/NetworkManager"
        {
          directory = "/etc/NetworkManager/system-connections";
          mode = "0700";
        }
      ];
    };
}
