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
      description = "Public key of this host's binary cache; its secret key goes in secrets.json at cache/signing-key.";
    };
  };

  flake.modules.nixos.forge =
    { config, ... }:
    let
      port = 5000;
    in
    lib.mkIf (config.axon.forge.cache != null) {
      # ── service ────────
      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [ config.sops.secrets."cache/signing-key".path ];
        settings.bind = "127.0.0.1:${toString port}";
      };

      # ── secrets ────────
      sops.secrets."cache/signing-key" = { };

      # ── registration ────────
      axon.services.cache = {
        units = [ "harmonia" ];
        route = {
          inherit port;
          gate = false;
        };
      };
    };
}
