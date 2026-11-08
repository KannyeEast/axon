# Nix itself: flakes, binary caches, cleanup through nh, and what a host needs to rebuild itself.
# Besides the public caches, the cache of any other host that runs one (the forge feature's
# host.toml [forge] cache), at cache.<domain>.
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

      # what a host needs to rebuild itself from the checkout: `just switch`
      environment.systemPackages = [
        pkgs.git
        pkgs.just
      ];

      nixpkgs.config.allowUnfree = true;

      system.stateVersion = host.state;
    };
}
