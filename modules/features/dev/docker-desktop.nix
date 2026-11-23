# Rootless Docker on desktops: DOCKER_HOST for shells, and a prune on nh's schedule.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      # ── service ────────
      virtualisation.docker.rootless.setSocketVariable = true;

      # ── session ────────
      # nixpkgs' autoPrune is for the rootful daemon only; this runs as the user, on nh's schedule
      systemd.user.services.docker-prune = {
        description = "Remove untagged Docker images and the build cache";
        wants = [ "docker.service" ];
        after = [ "docker.service" ];
        unitConfig.ConditionUser = [ config.axon.user.name ];
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
