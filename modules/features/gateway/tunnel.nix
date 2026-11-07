# Public services (route.public) are reachable from the internet through a Cloudflare Tunnel:
# this host dials out to Cloudflare, so no router port is opened and the home IP stays hidden.
# The tunnel is created once by hand (cloudflared tunnel create), its id goes in host.toml
# [gateway] and its credentials file in secrets.json as cloudflare-tunnel.
# Names aren't managed here either: every route is a DNS record at Cloudflare, pointing at this
# host's tailnet address, or at the tunnel for a public one (cloudflared tunnel route dns).
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
      inherit (config.axon) host routes gateway;
      public = filterAttrs (_: service: service.route.public) routes;
    in
    {
      assertions = lib.mapAttrsToList (name: service: {
        assertion = service.route.access == "open";
        message = "axon.services.${name}: a public service must bring its own login (access = \"open\"); the gateway login only guards the tailnet";
      }) public;

      warnings =
        lib.optional (public != { } && gateway.tunnel == null)
          "hosts/${host.name}/host.toml: ${concatStringsSep ", " (attrNames public)} would be public, but [gateway] has no tunnel yet";

      sops.secrets.cloudflare-tunnel = mkIf (gateway.tunnel != null) { };

      services.cloudflared = mkIf (gateway.tunnel != null && public != { }) {
        enable = true;
        tunnels.${gateway.tunnel} = {
          credentialsFile = config.sops.secrets.cloudflare-tunnel.path;
          default = "http_status:404";
          ingress = mapAttrs' (
            _: service: nameValuePair service.route.host "http://${service.route.endpoint}"
          ) public;
        };
      };
    };
}
