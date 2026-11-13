# Viewers: images in Loupe, text in GNOME Text Editor, videos in mpv (uosc interface, thumbnails,
# media keys through MPRIS), archives in File Roller. ~/.config/mimeapps.list maps the types.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.loupe
        pkgs.gnome-text-editor
        (pkgs.mpv.override {
          scripts = [
            pkgs.mpvScripts.mpris
            pkgs.mpvScripts.uosc
            pkgs.mpvScripts.thumbfast
          ];
        })
        pkgs.file-roller
      ];
    };
}
