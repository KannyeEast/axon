# The repository's remotes, from cluster.toml [repo]: checked (origin must be one of them) and
# given the forge's host and the repository's web address on it. Every mirror on another forge
# than the cluster's own domain is a link on the gateway's start page.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  # git@codeberg.org:me/axon.git and https://codeberg.org/me/axon.git -> [ "codeberg.org" "me/axon.git" ];
  # null for any other form
  partsOf =
    url:
    let
      ssh = lib.match "[^@/]+@([^:/]+):(.+)" url;
    in
    if ssh != null then ssh else lib.match "https?://([^/]+)/(.+)" url;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster remotes;
      inherit (cluster) domain repo;
      own = remote: domain != null && lib.hasSuffix domain remote.host;
    in
    {
      options.axon.remotes = mkOption {
        readOnly = true;
        default = lib.mapAttrs (
          name: url:
          let
            parts = partsOf url;
            origin = name == repo.origin;
          in
          {
            host = if parts == null then null else lib.elemAt parts 0;
            web =
              if parts == null then
                null
              else
                "https://${lib.elemAt parts 0}/${lib.removeSuffix ".git" (lib.elemAt parts 1)}";
            inherit origin;
            mirror = !origin && parts != null;
          }
        ) repo.remotes;
        defaultText = "cluster.toml [repo.remotes], with forge hosts and web addresses";
        description = "Remote name to the forge's host and the repository's web address (both null when the url is neither ssh nor https), whether it is origin, and whether it is a mirror (any other remote with a web address).";
        type = types.attrsOf (
          types.submodule {
            options = {
              host = mkOption { type = types.nullOr types.str; };
              web = mkOption { type = types.nullOr types.str; };
              origin = mkOption { type = types.bool; };
              mirror = mkOption { type = types.bool; };
            };
          }
        );
      };

      config = {
        assertions = [
          {
            assertion = repo.origin == null || repo.remotes ? ${repo.origin};
            message = "cluster.toml: [repo] origin '${toString repo.origin}' is not under [repo.remotes] (${lib.concatStringsSep ", " (lib.attrNames repo.remotes)})";
          }
        ];

        axon.links = lib.mapAttrs' (
          name: remote:
          lib.nameValuePair (lib.toSentenceCase name) {
            url = remote.web;
            icon = "${name}.svg";
            group = "Mirrors";
          }
        ) (lib.filterAttrs (_: remote: remote.mirror && !own remote) remotes);
      };
    };
}
