# The Jellyfin player (jellyfin-mpv-shim): browses the library in its own window and plays the
# files as they are in mpv, so the server doesn't transcode what a browser can't play (HDR,
# Dolby Vision, remux containers, lossless audio). It is also a cast target in Jellyfin's web UI.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.jellyfin-mpv-shim ];
    };
}
