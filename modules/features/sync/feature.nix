{
  axon.features.sync = {
    description = "Folders kept in sync between members with Syncthing, as cluster.toml [sync] says";
    classes = [
      "desktop"
      "server"
    ];
    spaces = {
      desktop = [ "syncthing" ];
      server = [ "syncthing" ];
    };
  };
}
