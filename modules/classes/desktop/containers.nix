# Rootless Docker: the daemon is a user unit, so a container's root is the user and no account
# joins the docker group. `docker compose` comes with the package. The sandbox (dev/sandbox.nix)
# runs on it.
{
  flake.modules.nixos.desktop =
    { config, ... }:
    {
      virtualisation.docker.rootless = {
        enable = true;
        # DOCKER_HOST for shells; the daemon's socket is in $XDG_RUNTIME_DIR
        setSocketVariable = true;
      };

      # nixpkgs' autoPrune is for the rootful daemon only; this runs as the user, on nh's schedule.
      # Untagged images and the build cache go; tagged images, containers and volumes stay
      systemd.user.services.docker-prune = {
        description = "Remove untagged Docker images and the build cache";
        wants = [ "docker.service" ];
        after = [ "docker.service" ];
        path = [ config.virtualisation.docker.rootless.package ];
        environment.DOCKER_HOST = "unix://%t/docker.sock";
        serviceConfig.Type = "oneshot";
        script = ''
          docker image prune --force
          docker builder prune --force
        '';
      };
      systemd.user.timers.docker-prune = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = config.programs.nh.clean.dates;
          Persistent = true;
        };
      };
    };
}
