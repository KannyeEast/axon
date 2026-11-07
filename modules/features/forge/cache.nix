# A Nix binary cache (harmonia) at cache.<domain>, tailnet only: it serves this host's store, which
# holds every host's latest system once CI has built it, so the others download their updates
# instead of building them. Without a login, since Nix can't do one; what it serves is signed with
# the key in secrets.json at forge/cache, whose public half is host.toml [forge] cache, and every
# other host trusts that. Without a public key there is no cache.
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

      axon.services.cache.route = {
        inherit port;
        access = "open"; # Nix can't log in; it checks the signature instead
      };
    };
}
