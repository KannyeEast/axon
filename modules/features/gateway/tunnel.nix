# Public services (route.public) are reachable from the internet through a Cloudflare Tunnel:
# node1 dials out to Cloudflare, so no router port is opened and the home IP stays hidden.
# The tunnel is created once by hand (cloudflared tunnel create), its id goes in host.toml
# [gateway] and its credentials file in secrets.json as cloudflare-tunnel.
# Cloudflare's terms don't allow streaming media through it: media stays on the tailnet.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatStringsSep
    filterAttrs
    mapAttrs'
    mkIf
    mkOption
    nameValuePair
    types
    ;
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
      inherit (config.axon) cluster services gateway;
      public = filterAttrs (_: service: service.route != null && service.route.public) services;
    in
    {
      assertions = [
        {
          assertion = public == { } || cluster.domain != null;
          message = "cluster.toml: public services need a domain";
        }
      ]
      ++ lib.mapAttrsToList (name: service: {
        assertion = service.route.access == "open";
        message = "axon.services.${name}: a public service must bring its own login (access = \"open\"); the gateway login only guards the tailnet";
      }) public;

      warnings = lib.optional (public != { } && gateway.tunnel == null) "gateway: ${concatStringsSep ", " (attrNames public)} would be public, but host.toml has no [gateway] tunnel yet";

      sops.secrets.cloudflare-tunnel = mkIf (gateway.tunnel != null) { };

      services.cloudflared = mkIf (gateway.tunnel != null && public != { }) {
        enable = true;
        tunnels.${gateway.tunnel} = {
          credentialsFile = config.sops.secrets.cloudflare-tunnel.path;
          default = "http_status:404";
          ingress = mapAttrs' (
            _: service:
            nameValuePair "${service.route.subdomain}.${cluster.domain}" "http://${service.route.address}:${toString service.route.port}"
          ) public;
        };
      };
    };
}
