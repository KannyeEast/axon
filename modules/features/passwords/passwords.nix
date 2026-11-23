# KeePassXC: the password manager and the system secret store (Secret Service).
# Settings: .config/keepassxc/keepassxc.ini.
# Windows: org.keepassxc.KeePassXC. Key: Mod+P.
{ lib, ... }:
{
  flake.modules.nixos.passwords =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      environment.systemPackages = [ pkgs.keepassxc ];

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

      # KeePassXC ships no D-Bus activation file, so an app asking before it is up drops its saved
      # login (Nextcloud at login); with this, D-Bus holds the call until the service owns the name
      services.dbus.packages = [
        (pkgs.writeTextDir "share/dbus-1/services/org.freedesktop.secrets.service" ''
          [D-BUS Service]
          Name=org.freedesktop.secrets
          Exec=${lib.getExe pkgs.keepassxc} --minimized
          SystemdService=keepassxc.service
        '')
      ];

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
