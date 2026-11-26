{
  axon.features.media = {
    description = "Movies and shows: Jellyfin on servers, the Jellyfin player on desktops";
    classes = [
      "desktop"
      "server"
    ];
    # only its server side keeps data
    spaces.server = [ "media" ];
  };
}
