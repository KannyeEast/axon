# Nextcloud client: syncs Nextcloud folders to this desktop.
# Settings: none.
# Windows: com.nextcloud.desktopclient.nextcloud.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [ pkgs.nextcloud-client ];
    };
}
