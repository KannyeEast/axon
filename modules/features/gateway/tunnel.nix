# Cloudflare Tunnel for public routes: the host dials out, so no router port opens and its IP hides.
# By hand: `cloudflared tunnel create`; its id into [gateway], its credentials as cloudflare/tunnel.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  axon.schema.gateway = {
    options.gateway.tunnel = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Cloudflare Tunnel id for public services; null keeps them off the internet.";
    };
  };

  flake.modules.nixos.gateway =
    { config, ... }:
    let
      inherit (config.axon) host routes gateway;
      public = lib.filterAttrs (_: service: service.route.public) routes;
    in
    {
      warnings =
        lib.optional (public != { } && gateway.tunnel == null)
          "hosts/${host.name}/host.toml: ${lib.concatStringsSep ", " (lib.attrNames public)} would be public, but [gateway] has no tunnel yet";

      sops.secrets."cloudflare/tunnel" = lib.mkIf (gateway.tunnel != null) { };

      services.cloudflared = lib.mkIf (gateway.tunnel != null && public != { }) {
        enable = true;
        tunnels.${gateway.tunnel} = {
          credentialsFile = config.sops.secrets."cloudflare/tunnel".path;
          default = "http_status:404";
          ingress = lib.mapAttrs' (
            _: service:
            lib.nameValuePair service.route.host {
              service = service.route.internal;
              originRequest.originServerName = lib.mkIf service.route.tls service.route.host;
            }
          ) public;
        };
      };
    };
}
