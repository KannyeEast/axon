# KeePassXC is the password manager and the system secret store (Secret Service), so apps
# that save passwords put them in the vault. Its settings, including [FdoSecrets], are
# dotfiles; this only installs it and starts it with the session.
{ lib, ... }:
{
  flake.modules.nixos.passwords =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.keepassxc ];

      # two secret stores fight over the same D-Bus name; GDM would bring gnome-keyring along
      services.gnome.gnome-keyring.enable = lib.mkForce false;

      systemd.user.services.keepassxc = {
        description = "KeePassXC";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.keepassxc} --minimized";
          Restart = "on-failure";
        };
      };
    };
}
