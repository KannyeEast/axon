# Contract: axon.services. What a service offers the rest of the cluster. On a host without the
# gateway or backup feature nobody reads it; a server warns (server/headless.nix), as its routes
# then reach no other machine.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon)
        cluster
        domain
        host
        services
        ;
    in
    {
      options.axon.domain = mkOption {
        type = types.str;
        readOnly = true;
        default =
          if cluster.domain != null then
            cluster.domain
          else
            throw "cluster.toml: something on ${host.name} needs a domain; set domain at the top";
        defaultText = "domain in cluster.toml";
        description = "The cluster's domain, for what can't work without one. What can reads axon.cluster.domain and handles null.";
      };

      options.axon.routed = mkOption {
        type = types.bool;
        default = false;
        description = "Set by the gateway: this host serves the routes in axon.services. Consumers fall back when it doesn't.";
      };

      options.axon.routes = mkOption {
        type = types.attrsOf types.raw;
        readOnly = true;
        default = lib.filterAttrs (_: service: service.route != null) services;
        defaultText = "the entries of axon.services with a route";
        description = "This host's services that have a route.";
      };

      options.axon.services = mkOption {
        default = { };
        description = "One producer per entry, any number of consumers. Consumers must work with an empty set.";
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            {
              options = {
                route = mkOption {
                  default = null;
                  description = "Publish through the gateway as <name>.<cluster domain>.";
                  type = types.nullOr (
                    types.submodule (route: {
                      options = {
                        port = mkOption { type = types.port; };
                        address = mkOption {
                          type = types.str;
                          default = "127.0.0.1";
                        };
                        host = mkOption {
                          type = types.str;
                          readOnly = true;
                          default = "${name}.${domain}";
                          defaultText = "<name>.<domain>";
                          description = "The name it's published under.";
                        };
                        url = mkOption {
                          type = types.str;
                          readOnly = true;
                          default = "https://${route.config.host}";
                          defaultText = "https://<host>";
                          description = "Where clients reach it, through the gateway.";
                        };
                        endpoint = mkOption {
                          type = types.str;
                          readOnly = true;
                          default = "${route.config.address}:${toString route.config.port}";
                          defaultText = "<address>:<port>";
                          description = "Where the service itself answers, on this host.";
                        };
                        name = mkOption {
                          type = types.str;
                          readOnly = true;
                          default = if config.axon.routed then route.config.host else route.config.address;
                          defaultText = "host behind the gateway, else address";
                          description = "The name the service answers to, for its own settings.";
                        };
                        origin = mkOption {
                          type = types.str;
                          readOnly = true;
                          default = if config.axon.routed then route.config.url else route.config.internal;
                          defaultText = "url behind the gateway, else internal";
                          description = "Where the service links to itself, for its own settings.";
                        };
                        tls = mkOption {
                          type = types.bool;
                          default = false;
                          description = "The service itself speaks HTTPS, with the gateway's certificate for host.";
                        };
                        internal = mkOption {
                          type = types.str;
                          readOnly = true;
                          default = "${if route.config.tls then "https" else "http"}://${route.config.endpoint}";
                          defaultText = "http://<endpoint>, https:// with tls";
                          description = "The service's own address, for callers on this host.";
                        };
                        public = mkOption {
                          type = types.bool;
                          default = false;
                          description = "Also reachable from the internet through the gateway's tunnel; on the tailnet either way. Only for services with their own login: the tunnel bypasses the gate.";
                        };
                        gate = mkOption {
                          type = types.bool;
                          default = false;
                          description = "A login through the gateway's oauth2-proxy in front of the route.";
                        };
                      };
                    })
                  );
                };

                dashboard = mkOption {
                  default = null;
                  description = "A tile on the gateway's start page, linked to the route.";
                  type = types.nullOr (
                    types.submodule (dashboard: {
                      options = {
                        name = mkOption { type = types.str; };
                        group = mkOption { type = types.str; };
                        order = mkOption {
                          type = types.int;
                          default = 100;
                          description = "Position within its group, which fills rows left to right; equal positions go alphabetically.";
                        };
                        description = mkOption {
                          type = types.str;
                          default = "";
                        };
                        icon = mkOption {
                          type = types.str;
                          description = "A name from homarr-labs/dashboard-icons, e.g. jellyfin.svg.";
                        };
                        monitor = mkOption {
                          type = types.str;
                          default = "/";
                          description = "Path the status dot requests; it follows redirects, so it must not lead off plain http.";
                        };
                        widget = mkOption {
                          type = types.nullOr (types.attrsOf types.anything);
                          default = null;
                          description = "Homepage widget settings; url defaults to the route's address.";
                        };
                        key = mkOption {
                          type = types.bool;
                          default = false;
                          description = "The widget needs the service's API key, kept in the gateway host's secrets.json at dashboard/<name>/key.";
                        };
                        secrets = mkOption {
                          type = types.attrsOf types.str;
                          default = lib.optionalAttrs dashboard.config.key { key = "dashboard/${name}/key"; };
                          defaultText = "{ key = \"dashboard/<name>/key\"; } with key, else { }";
                          description = "Widget field -> key in the gateway host's secrets.json that holds its value.";
                        };
                        instances = mkOption {
                          default = { };
                          description = "One tile per entry instead of one, named by the key.";
                          type = types.attrsOf (
                            types.submodule {
                              options = {
                                widget = mkOption {
                                  type = types.attrsOf types.anything;
                                  default = { };
                                  description = "Merged over the service's widget.";
                                };
                                link = mkOption {
                                  type = types.nullOr types.str;
                                  default = null;
                                  description = "Where the tile leads instead of the route.";
                                };
                                group = mkOption {
                                  type = types.nullOr types.str;
                                  default = null;
                                  description = "Its group instead of the service's.";
                                };
                                description = mkOption {
                                  type = types.nullOr types.str;
                                  default = null;
                                };
                              };
                            }
                          );
                        };
                      };
                    })
                  );
                };

                space = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "The volume or space in host.toml [limits] whose use its tile shows, against that limit.";
                };

                units = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Its systemd services, by name without .service: helpers, timers' jobs, its own Redis and its container's unit included. Their logs, a container's own lines too, go under its name.";
                };

                backup = {
                  paths = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Backed up by the backup feature. Empty means not backed up.";
                  };
                  exclude = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                  };
                };
              };
            }
          )
        );
      };
    };
}
