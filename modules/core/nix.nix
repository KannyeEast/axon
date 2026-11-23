# Nix itself: flakes, binary caches (the public ones and any host's [forge] cache at
# cache.<domain>), cleanup through nh, and what a host needs to rebuild itself.
{ lib, ... }:
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon) cluster host repo;
      caches = lib.filter (key: key != null) (
        lib.mapAttrsToList (name: data: if name == host.name then null else data.forge.cache or null) (
          cluster.hosts
        )
      );
      own = lib.optionals (cluster.domain != null && caches != [ ]) [ "https://cache.${cluster.domain}" ];
    in
    {
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [ "@wheel" ];
        auto-optimise-store = true;
        # large closures overflow the default buffer
        download-buffer-size = 500000000;
        warn-dirty = false;

        # cache.nixos.org and its key are added by NixOS
        substituters = [ "https://nix-community.cachix.org" ] ++ own;
        trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ]
        ++ caches;
        # an unreachable cache (off the tailnet) costs seconds, not minutes
        connect-timeout = 5;
      };

      programs.nh = {
        enable = true;
        flake = repo;
        clean.enable = true;
        clean.extraArgs = "--keep-since 4d --keep 5";
      };

      # `just switch` rebuilds the host from its checkout, with git from remotes.nix
      environment.systemPackages = [ pkgs.just ];

      nixpkgs.config.allowUnfree = true;

      system.stateVersion = host.state;
    };
}
