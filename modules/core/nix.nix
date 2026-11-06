# Nix itself: flakes, binary caches, cleanup through nh, and what a host needs to rebuild itself.
{
  flake.modules.nixos.core =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host repo;
    in
    {
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [
          "root"
          "@wheel"
        ];
        auto-optimise-store = true;
        # large closures overflow the default buffer
        download-buffer-size = 500000000;
        warn-dirty = false;

        substituters = [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
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
