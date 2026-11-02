# The Beszel hub at monitor.<domain>: collects from the agent on every host in the cluster
# (core/metrics.nix), keeps the history, draws the graphs and sends the alerts. The host list is
# generated from the cluster; thresholds and notifications are set in its UI.
# Beszel's own login; the account is created on first start from host.toml's email and
# monitoring/password.
# The hub makes its key pair on first start; its public key goes into host.toml
# [monitoring] key, and the agents start once it's there.
{ lib, ... }:
let
  inherit (lib)
    attrNames
    concatMapStrings
    genAttrs
    mkOption
    types
    ;
in
{
  axon.schema.monitoring = {
    options.monitoring.key = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The hub's public key, from Beszel's \"Add system\" dialog after its first start.";
    };
  };

  flake.modules.nixos.monitoring =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        cluster
        host
        user
        monitoring
        ;
      port = 8092;
      dataDir = "/var/lib/private/beszel-hub";

      # synced into the hub's database on every start
      systems = pkgs.writeText "beszel-config.yml" ''
        systems:
        ${concatMapStrings (name: ''
          - name: ${name}
            host: ${name}
            users:
              - ${user.email}
        '') (attrNames cluster.hosts)}
      '';
    in
    {
      warnings =
        lib.optional (monitoring.key == null)
          "hosts/${host.name}/host.toml: no [monitoring] key yet, so no agent reports; copy it from Beszel's \"Add system\" dialog";

      services.beszel.hub = {
        enable = true;
        inherit port;
        environment.USER_EMAIL = user.email;
        environmentFile = config.sops.templates."beszel-hub.env".path;
      };

      # the hub's data folder is beszel_data under its working directory
      systemd.services.beszel-hub.preStart = ''
        mkdir -p beszel_data
        ln -sf ${systems} beszel_data/config.yml
      '';

      sops.secrets."monitoring/password" = { };
      sops.templates."beszel-hub.env" = {
        content = ''
          USER_PASSWORD=${config.sops.placeholder."monitoring/password"}
        '';
        restartUnits = [ "beszel-hub.service" ];
      };

      axon.persist.directories = [
        {
          directory = dataDir;
          mode = "0700";
        }
      ];

      axon.services.monitor = {
        route = {
          inherit port;
          access = "open";
        };
        dashboard = {
          name = "Beszel";
          group = "System";
          icon = "beszel.svg";
          widget = {
            type = "beszel";
            version = 2;
            username = user.email;
            fields = [
              "cpu"
              "memory"
              "disk"
              "network"
            ];
          };
          secrets.password = "monitoring/password";
          instances = genAttrs (attrNames cluster.hosts) (name: {
            systemId = name;
          });
        };
        backup.paths = [ dataDir ];
      };
    };
}
