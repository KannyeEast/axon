# Rootless Docker for the owner: the daemon is a user unit, so a container's root is the user and
# no account joins the docker group.
{
  flake.modules.nixos.dev =
    { config, ... }:
    {
      # ── service ────────
      virtualisation.docker.rootless.enable = true;

      # ── session ────────
      # other accounts with a user manager (git over SSH as forgejo, the greeter) have no subuid
      # range, so the daemon fails for them on every login
      systemd.user.services.docker.unitConfig.ConditionUser = [ config.axon.user.name ];
    };
}
