# The flake's own outputs: systems, the formatter and the host.toml reference.
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

      # the host.toml and cluster.toml reference, TOML-like so `just docs` can highlight it
      packages.options =
        let
          doc = pkgs.nixosOptionsDoc {
            options =
              removeAttrs
                (lib.evalModules {
                  modules = lib.attrValues config.axon.schema ++ [
                    {
                      options.cluster = lib.mkOption {
                        type = lib.types.submodule config.axon.clusterSchema;
                        description = "cluster.toml: how the machines relate, and where this repository is pushed.";
                      };
                    }
                  ];
                }).options
                [ "_module" ];
          };
        in
        pkgs.runCommand "options.toml" { nativeBuildInputs = [ pkgs.jq ]; } ''
          jq -r 'to_entries[] | (.value.description | rtrimstr("\n") | gsub("(?m)^"; "# ")) + "\n"
            + (.key | gsub("<name>"; "\"<name>\"")) + (if .value.default then " = " + (.value.default.text | gsub("\n\\s*"; " ")) else "" end)
            + "  # " + .value.type + "\n"' \
            ${doc.optionsJSON}/share/doc/nixos/options.json > $out
        '';
    };
}
