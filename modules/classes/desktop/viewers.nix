# Apps that open files from the file manager or a link: images in Loupe, text and logs in
# GNOME Text Editor, local videos in mpv, archives in File Roller. Which app opens which type
# is the dotfile ~/.config/mimeapps.list. mpv gets a modern interface with thumbnails, and shows
# up for media keys through MPRIS.
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
