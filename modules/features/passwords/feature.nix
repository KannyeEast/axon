{
  axon.features.passwords = {
    description = "Passwords: on servers Vaultwarden; on desktops the Bitwarden extension and gnome-keyring where a server runs it, else KeePassXC as password manager and system secret store";
    classes = [
      "desktop"
      "server"
    ];
    # only its server side keeps data
    spaces.server = [ "backups" ];
  };
}
