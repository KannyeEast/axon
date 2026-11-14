# deploy.nodes.<host> for deploy-rs: logs in as root, builds on the host and rolls back when the
# host stops answering after the switch.
{
  inputs,
  config,
  lib,
  ...
}:
{
  flake.deploy.nodes = lib.mapAttrs (
    name: host:
    let
      # the activation helper from nixpkgs' deploy-rs, which the binary cache has; the flake's own
      # would be compiled against this nixpkgs
      pkgs = host.pkgs.appendOverlays [
        inputs.deploy-rs.overlays.default
        (final: prev: {
          deploy-rs = {
            inherit (host.pkgs) deploy-rs;
            inherit (prev.deploy-rs) lib;
          };
        })
      ];
    in
    {
      hostname = name;
      sshUser = "root";
      remoteBuild = true;
      profiles.system.path = pkgs.deploy-rs.lib.activate.nixos host;
    }
  ) config.flake.nixosConfigurations;
}
