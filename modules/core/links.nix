# Contract: axon.links. Admin pages of what this host relies on outside the cluster, listed by
# whatever relies on it. A gateway shows them on its start page; elsewhere nobody reads them.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core = {
    options.axon.links = mkOption {
      default = { };
      description = "Name to admin page.";
      type = types.attrsOf (
        types.submodule {
          options = {
            url = mkOption { type = types.str; };
            icon = mkOption {
              type = types.str;
              description = "A name from homarr-labs/dashboard-icons, e.g. mullvad.svg.";
            };
          };
        }
      );
    };
  };
}
