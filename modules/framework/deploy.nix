# deploy.nodes.<host> for deploy-rs: built on the host, rolled back when it stops answering.
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
      # nixpkgs' deploy-rs is in the binary cache; the flake's own would be compiled here
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
