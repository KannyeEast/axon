# Harmonia at cache.<domain>: a Nix binary cache of this host's store, where CI builds every system.
# Reach: tailnet, no login.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  axon.schema.forge = {
    options.forge.cache = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "cache.example.com-1:AbCd…=";
      description = "Public key of this host's binary cache; its secret key goes in secrets.json at forge/cache.";
    };
  };

  flake.modules.nixos.forge =
    { config, ... }:
    let
      port = 5000;
    in
    lib.mkIf (config.axon.forge.cache != null) {
      sops.secrets."forge/cache" = { };

      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [ config.sops.secrets."forge/cache".path ];
        settings.bind = "127.0.0.1:${toString port}";
      };

      axon.services.cache = {
        units = [ "harmonia" ];
        route = {
          inherit port;
          gate = false;
        };
      };
    };
}
