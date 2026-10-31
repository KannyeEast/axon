{
  inputs,
  config,
  lib,
  ...
}:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];

  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt;

      # the host.toml and cluster.toml reference, generated from the schema pieces:
      # nix build .#options && cat result
      packages.options =
        (pkgs.nixosOptionsDoc {
          options =
            (lib.evalModules {
              modules = builtins.attrValues config.axon.schema ++ [
                { options.cluster = lib.mkOption { type = lib.types.submodule config.axon.clusterSchema; }; }
              ];
            }).options;
          warningsAreErrors = false;
        }).optionsCommonMark;

      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.just
          pkgs.nixfmt
          pkgs.deadnix
          pkgs.sops
          pkgs.ssh-to-age
        ];
      };
    };
}
