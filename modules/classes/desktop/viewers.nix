# Apps that open files from the file manager or a link: images in Loupe, text and logs in
# GNOME Text Editor, local videos in mpv, archives in File Roller. Which app opens which type
# is the dotfile ~/.config/mimeapps.list.
{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.loupe
        pkgs.gnome-text-editor
        pkgs.mpv
        pkgs.file-roller
      ];
    };
}
