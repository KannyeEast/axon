# Viewers: Loupe (images), GNOME Text Editor, mpv (uosc, thumbnails, MPRIS), File Roller.
# Settings: ~/.config/mimeapps.list, ~/.config/mpv/mpv.conf.
# Windows: org.gnome.Loupe, org.gnome.TextEditor, mpv (floats), org.gnome.FileRoller.
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
