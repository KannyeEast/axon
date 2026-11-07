# The flake's own outputs: systems, the formatter, the host.toml reference and the devshell.
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
      # the tree wrapper: bare nixfmt only formats the files it's given
      formatter = pkgs.nixfmt-tree;

      # the host.toml and cluster.toml reference, generated from the schema pieces:
      # nix build .#options && cat result
      packages.options =
        (pkgs.nixosOptionsDoc {
          options =
            (lib.evalModules {
              modules = lib.attrValues config.axon.schema ++ [
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
