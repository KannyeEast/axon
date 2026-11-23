# Rootless Docker for the owner: the daemon is a user unit, so a container's root is the user and
# no account joins the docker group.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, ... }:
    let
      # other accounts with a user manager (git over SSH as forgejo, the greeter) have no subuid
      # range, so the daemon fails for them on every login
      owner = [ config.axon.user.name ];
    in
    lib.mkMerge [
      {
        virtualisation.docker.rootless.enable = true;
        systemd.user.services.docker.unitConfig.ConditionUser = owner;
      }

      (lib.mkIf (config.axon.host.class == "desktop") {
        virtualisation.docker.rootless.setSocketVariable = true;

        # nixpkgs' autoPrune is for the rootful daemon only; this runs as the user, on nh's schedule
        systemd.user.services.docker-prune = {
          description = "Remove untagged Docker images and the build cache";
          wants = [ "docker.service" ];
          after = [ "docker.service" ];
          unitConfig.ConditionUser = owner;
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
      })
    ];
}
