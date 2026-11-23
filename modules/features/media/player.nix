# Jellyfin player (jellyfin-mpv-shim): plays files as they are, so the server doesn't transcode.
# Settings: .config/jellyfin-mpv-shim/mpv.conf.
# Windows: com.github.iwalton3.jellyfin-mpv-shim.
{ lib, ... }:
{
  flake.modules.nixos.media =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [ pkgs.jellyfin-mpv-shim ];

      systemd.user.services.jellyfin-mpv-shim = {
        description = "Jellyfin player";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.jellyfin-mpv-shim} --minimized";
          Restart = "on-failure";
        };
      };
    };
}
