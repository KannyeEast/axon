# The repository's remotes, from cluster.toml [repo]: checked (origin must be one of them) and
# given the web address of the repository on each forge. Every mirror, so every remote but
# origin and those on the cluster's own domain, is a link on the gateway's start page.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatStringsSep
    elemAt
    escapeRegex
    filterAttrs
    mapAttrs'
    mapAttrs
    nameValuePair
    match
    mkOption
    removeSuffix
    substring
    toUpper
    types
    ;

  capitalise = name: toUpper (substring 0 1 name) + substring 1 (-1) name;

  # git@codeberg.org:me/axon.git and https://codeberg.org/me/axon.git -> https://codeberg.org/me/axon;
  # null for any other form
  webOf =
    url:
    let
      parts =
        if match "[^@/]+@[^:/]+:.+" url != null then
          match "[^@/]+@([^:/]+):(.+)" url
        else
          match "https?://([^/]+)/(.+)" url;
    in
    if parts == null then null else "https://${elemAt parts 0}/${removeSuffix ".git" (elemAt parts 1)}";
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) cluster remotes;
      inherit (cluster) domain repo;
      own = remote: domain != null && match "https://[^/]*${escapeRegex domain}/.*" remote.web != null;
    in
    {
      options.axon.remotes = mkOption {
        readOnly = true;
        default = mapAttrs (name: url: {
          inherit url;
          web = webOf url;
          origin = name == repo.origin;
        }) repo.remotes;
        defaultText = "cluster.toml [repo.remotes], with web addresses";
        description = "Remote name to its git url, the repository's web address (null when the url is neither ssh nor https) and whether it is origin.";
        type = types.attrsOf (
          types.submodule {
            options = {
              url = mkOption { type = types.str; };
              web = mkOption { type = types.nullOr types.str; };
              origin = mkOption { type = types.bool; };
            };
          }
        );
      };

      config = {
        assertions = [
          {
            assertion = repo.origin == null || repo.remotes ? ${repo.origin};
            message = "cluster.toml: [repo] origin '${toString repo.origin}' is not under [repo.remotes] (${concatStringsSep ", " (attrNames repo.remotes)})";
          }
        ];

        axon.links = mapAttrs' (
          name: remote:
          nameValuePair (capitalise name) {
            url = remote.web;
            icon = "${name}.svg";
            group = "Mirrors";
          }
        ) (filterAttrs (_: remote: !remote.origin && remote.web != null && !own remote) remotes);
      };
    };
}
