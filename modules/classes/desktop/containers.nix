# Rootless Docker: the daemon is a user unit, so a container's root is the user and no account
# joins the docker group. `docker compose` comes with the package. The sandbox (dev/sandbox.nix)
# runs on it.
{
  flake.modules.nixos.desktop = {
    virtualisation.docker.rootless = {
      enable = true;
      # DOCKER_HOST for shells; the daemon's socket is in $XDG_RUNTIME_DIR
      setSocketVariable = true;
    };
  };
}
