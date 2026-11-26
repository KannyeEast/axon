{
  axon.features.forge = {
    description = "Hosting code: Forgejo for git repositories, Renovate for the pull requests that update them";
    classes = [ "server" ];
    spaces.server = [
      "backups"
      "databases"
      "forgejo"
    ];
  };
}
