{
  axon.features.files = {
    description = "Your data on a server: Nextcloud (public for share links), photos and documents; the Nextcloud client on desktops";
    classes = [
      "desktop"
      "server"
    ];
    # only its server side keeps data
    spaces.server = [
      "backups"
      "databases"
      "immich"
      "nextcloud"
      "paperless"
    ];
  };
}
