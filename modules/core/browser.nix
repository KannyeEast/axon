# Contract: axon.browser. What other features need from a browser: they list it here and the
# browser feature applies it. On a host without one nobody reads it.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core = {
    options.axon.browser = {
      extensions = mkOption {
        default = { };
        description = "Extensions to install, by extension id.";
        type = types.attrsOf (
          types.submodule {
            options = {
              id = mkOption {
                type = types.str;
                description = "Its name on addons.mozilla.org.";
              };
              pinned = mkOption {
                type = types.bool;
                default = false;
                description = "Shown in the toolbar.";
              };
              private = mkOption {
                type = types.bool;
                default = false;
                description = "Also runs in private windows.";
              };
            };
          }
        );
      };
      nativeHosts = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Apps that extensions may talk to, as native messaging hosts.";
      };
    };
  };
}
