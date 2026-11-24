# Contract: axon.services. What a service offers the rest of the cluster: the gateway reads its
# routes and start-page tiles, backup its paths, metrics its units for the log labels. A server
# without the gateway warns (server/headless.nix), as its routes then reach no other machine.
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

      options.axon.gated = mkOption {
        type = types.bool;
        default = false;
        description = "Set by the gateway: its login is in effect on this host.";
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
                        port = mkOption {
                          type = types.port;
                          description = "The port the service listens on.";
                        };
                        address = mkOption {
                          type = types.str;
                          default = "127.0.0.1";
                          description = "The address the service listens on.";
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
                          default = "${
                            if route.config.tls then "https" else "http"
                          }://${route.config.address}:${toString route.config.port}";
                          defaultText = "http://<address>:<port>, https:// with tls";
                          description = "The service's own address, for callers on this host.";
                        };
                        public = mkOption {
                          type = types.bool;
                          default = false;
                          description = "Also reachable from the internet through the gateway's tunnel; on the tailnet either way. Only for services with their own login: the tunnel bypasses the gate.";
                        };
                        gate = mkOption {
                          type = types.bool;
                          default = !route.config.public;
                          defaultText = "!public";
                          description = "The gateway's login (oauth2-proxy) in front of the route; false for what can't follow a browser login.";
                        };
                        gated = mkOption {
                          type = types.bool;
                          readOnly = true;
                          default = route.config.gate && config.axon.gated;
                          defaultText = "gate, where the gateway's login is in effect";
                          description = "The gateway's login is in front of the route.";
                        };
                        health = mkOption {
                          type = types.str;
                          default = "";
                          description = "Path the health checks (the start page's status dot, the monitoring probes) request after internal and url; empty is the root. The status dot follows redirects, so it must not lead off plain http.";
                        };
                      };
                    })
                  );
                };

                dashboard = mkOption {
                  default = null;
                  description = "A tile on the gateway's start page, linked to the route.";
                  type = types.nullOr (
                    types.submodule {
                      options = {
                        name = mkOption {
                          type = types.str;
                          description = "The tile's title.";
                        };
                        group = mkOption {
                          type = types.str;
                          description = "The start-page group the tile sits in.";
                        };
                        order = mkOption {
                          type = types.int;
                          default = 100;
                          description = "Position within its group, which fills rows left to right; equal positions go alphabetically.";
                        };
                        description = mkOption {
                          type = types.str;
                          default = "";
                          description = "The line under the tile's title.";
                        };
                        icon = mkOption {
                          type = types.str;
                          description = "A name from homarr-labs/dashboard-icons, e.g. jellyfin.svg.";
                        };
                        widget = mkOption {
                          type = types.nullOr (types.attrsOf types.anything);
                          default = null;
                          description = "Homepage widget settings; url defaults to the route's address, for a prometheusmetric widget to the cluster's Prometheus (shown only where the gateway host lists metrics and a host runs monitoring).";
                        };
                        key = mkOption {
                          type = types.bool;
                          default = false;
                          description = "The widget needs the service's API key, <name>/api-key in the gateway host's secrets.json.";
                        };
                        space = mkOption {
                          type = types.nullOr types.str;
                          default = null;
                          description = "The space (axon.spaces) whose use its tile shows, with its limit where it has one; shown while a data disk holds it.";
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
                                  description = "Its line under the title instead of the service's.";
                                };
                              };
                            }
                          );
                        };
                      };
                    }
                  );
                };

                apiKey = mkOption {
                  type = types.str;
                  readOnly = true;
                  default = "${name}/api-key";
                  defaultText = "<name>/api-key";
                  description = "The name of the service's API key in secrets.json, for whatever on this host calls its API.";
                };

                units = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Its systemd services, by name without .service: helpers, timers' jobs, its own Redis and its container's unit included. Their logs, a container's own lines too, go under its name.";
                };

                logStart = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "^\\[(Trace|Debug|Info|Warn|Error|Fatal)\\]";
                  description = "A regular expression for the first line of an entry in its units' logs; the lines after it that don't match, such as a stack trace, join that entry.";
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
                    description = "Left out of the backup, below paths.";
                  };
                };
              };
            }
          )
        );
      };
    };
}
