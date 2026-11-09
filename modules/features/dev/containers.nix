# One container engine: rootless podman. `docker` and `docker compose` are aliases for it,
# so projects written for Docker run unchanged, without a root-equivalent docker group.
# The sandbox (sandbox.nix) runs on it too.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    lib.mkIf (config.axon.host.class == "desktop") {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true; # containers in a compose file find each other by name
        autoPrune.enable = true;
      };

      environment.systemPackages = [ pkgs.podman-compose ];
    };
}
