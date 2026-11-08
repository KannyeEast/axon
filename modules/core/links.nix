# Contract: axon.links. Pages of what this host relies on outside the cluster, listed by
# whatever relies on it, in groups by purpose. A gateway shows them on its start page; elsewhere
# nobody reads them.
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
            group = mkOption {
              type = types.str;
              default = "Infrastructure";
              description = "The heading it is listed under; services' group names are taken.";
            };
          };
        }
      );
    };
  };
}
