# The Jellyfin player (jellyfin-mpv-shim): browses the library in its own window and plays the
# files as they are in mpv, so the server doesn't transcode what a browser can't play (HDR,
# Dolby Vision, remux containers, lossless audio). It starts minimized with the session, so it
# is a cast target in Jellyfin's web UI and apps without being opened first; launching it again
# shows the window.
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
