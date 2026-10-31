# One container engine: rootless podman. `docker` and `docker compose` are aliases for it,
# so projects written for Docker run unchanged, without a root-equivalent docker group.
# The sandbox (sandbox.nix) runs on it too.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    {
      config = lib.mkIf (config.axon.host.class == "desktop") {
        virtualisation.podman = {
          enable = true;
          dockerCompat = true;
          defaultNetwork.settings.dns_enabled = true; # containers in a compose file find each other by name
          autoPrune = {
            enable = true;
            dates = "weekly";
          };
        };
        # rootless containers need a range of subordinate ids for the user
        users.users.${config.axon.user.name}.autoSubUidGidRange = true;

        environment.systemPackages = [ pkgs.podman-compose ];
      };
    };
}
