# On desktops, KeePassXC is the password manager and the system secret store (Secret Service),
# so apps that save passwords put them in the vault. Its settings, including [FdoSecrets], are
# dotfiles; this only installs it and starts it with the session.
{ lib, ... }:
{
  flake.modules.nixos.passwords =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [ pkgs.keepassxc ];

      # the browser extension, the link that lets it talk to the app, and the browser's own password
      # saving out of the way
      axon.browser = {
        extensions."keepassxc-browser@keepassxc.org" = {
          id = "keepassxc-browser";
          pinned = true;
          private = true;
        };
        nativeHosts = [ pkgs.keepassxc ];
        policies = {
          OfferToSaveLogins = false;
          PasswordManagerEnabled = false;
        };
      };

      # two secret stores fight over the same D-Bus name; niri turns gnome-keyring on
      services.gnome.gnome-keyring.enable = false;

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
