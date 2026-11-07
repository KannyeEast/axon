# The Nextcloud client on desktops: it syncs Nextcloud folders to this machine.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [ pkgs.nextcloud-client ];
    };
}
