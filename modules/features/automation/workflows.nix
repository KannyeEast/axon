# n8n at automation.<domain>: workflows that tie the services together. Tailnet only, behind the
# gate and n8n's own login, whose owner account is made on the first visit. Callers on this host
# send webhooks to its internal address, past the gate. The workflows are the files in
# .config/n8n/workflows from the checkout (hosts/<name>/home wins per file), imported before every
# start and on a change; those with "active": true are published. A UI edit is lost on the next
# start unless downloaded back into its file; a deleted file leaves its workflow in n8n. Workflow
# nodes read the API keys (secrets.json's dashboard/<name>/key as <NAME>_API_KEY) from n8n's
# environment. The rest lives in its database, encrypted with a key n8n makes itself in the same
# folder.
{ lib, ... }:
{
  flake.modules.nixos.automation =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host;
      inherit (config.axon.services.automation) route;
      inherit (config.services.prometheus) alertmanager;
      state = "/var/lib/private/n8n";
      dirs = map (home: "${home}/.config/n8n/workflows") (lib.reverseList config.axon.dotfiles);
      # n8n's DynamicUser can't read the checkout under the user's 0700 home: root copies the files
      # here first, later ones replacing earlier ones of the same name
      copied = "/run/n8n-import";
      n8n = config.systemd.services.n8n;

      secret = name: "dashboard/${name}/key";
      keys = lib.attrNames (
        lib.filterAttrs (_: secrets: secrets ? key) (config.axon.secrets.dashboard or { })
      );
      envName = name: "${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name)}_API_KEY";

      copy = pkgs.writeShellApplication {
        name = "n8n-copy-workflows";
        text = ''
          shopt -s nullglob
          for dir in ${lib.escapeShellArgs dirs}; do
            for file in "$dir"/*.json; do
              install -m 0444 "$file" ${copied}/
            done
          done
        '';
      };
      load = pkgs.writeShellApplication {
        name = "n8n-import";
        runtimeInputs = [
          config.services.n8n.package
          pkgs.jq
        ];
        text = ''
          shopt -s nullglob
          failed=0
          # n8n skips such a file with only a warning, and gives one without an id a new copy each time
          for file in ${copied}/*.json; do
            if ! jq -e 'type == "object" and (.id | type) == "string" and has("nodes") and has("connections")' "$file" >/dev/null; then
              echo "$(basename "$file"): not a workflow with id, nodes and connections, skipped"
              rm "$file"
              failed=1
            fi
          done
          files=(${copied}/*.json)
          if [ ''${#files[@]} -gt 0 ]; then
            # it deactivates every workflow it imports
            n8n import:workflow --separate --input=${copied}
            for file in "''${files[@]}"; do
              if jq -e '.active == true' "$file" >/dev/null; then
                n8n publish:workflow --id="$(jq -r .id "$file")"
              fi
            done
          fi
          exit "$failed"
        '';
      };
    in
    {
      services.n8n = {
        enable = true;
        environment = {
          N8N_LISTEN_ADDRESS = "127.0.0.1";
          N8N_WEBHOOK_URL = route.origin;
          # the gateway: client addresses come from X-Forwarded-For
          N8N_PROXY_HOPS = 1;
          # its AI workflow builder, on by default, asks for a model; none is set up
          N8N_DISABLED_MODULES = "instance-ai";
          # workflow nodes read the API keys and addresses below as {{ $env.X }}
          N8N_BLOCK_ENV_ACCESS_IN_NODE = false;
          AXON_HOST = host.name;
        }
        // lib.optionalAttrs alertmanager.enable {
          ALERTMANAGER_URL = "http://127.0.0.1:${toString alertmanager.port}";
        };
      };

      systemd.services.n8n.serviceConfig.EnvironmentFile = lib.mkIf (
        keys != [ ]
      ) config.sops.templates."n8n.env".path;

      sops.secrets = lib.genAttrs (map secret keys) (_: { });
      sops.templates."n8n.env" = lib.mkIf (keys != [ ]) {
        content = lib.concatMapStrings (
          name: "${envName name}=${config.sops.placeholder.${secret name}}\n"
        ) keys;
        restartUnits = [ "n8n.service" ];
      };

      # a broken file fails this unit, not n8n
      systemd.services.n8n-import = {
        description = "Import the n8n workflows from the checkout";
        wantedBy = [ "n8n.service" ];
        before = [ "n8n.service" ];
        environment = removeAttrs n8n.environment [ "PATH" ];
        serviceConfig = {
          Type = "oneshot";
          User = "n8n";
          RuntimeDirectory = "n8n-import";
          ExecStartPre = "+${lib.getExe copy}";
          ExecStart = lib.getExe load;
          # n8n's own sandbox
          inherit (n8n.serviceConfig)
            DynamicUser
            StateDirectory
            LoadCredential
            NoNewPrivileges
            PrivateTmp
            PrivateDevices
            DevicePolicy
            ProtectSystem
            ProtectHome
            ProtectControlGroups
            ProtectKernelModules
            ProtectKernelTunables
            RestrictAddressFamilies
            RestrictNamespaces
            RestrictRealtime
            RestrictSUIDSGID
            MemoryDenyWriteExecute
            LockPersonality
            ;
        };
      };
      systemd.paths.n8n-workflows = {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = dirs;
      };
      systemd.services.n8n-workflows = {
        description = "Restart n8n on new workflow files";
        serviceConfig = {
          Type = "oneshot";
          # its restart imports them first
          ExecStart = "${pkgs.systemd}/bin/systemctl restart n8n.service";
        };
      };

      warnings =
        lib.optional (!alertmanager.enable)
          "hosts/${host.name}/host.toml: no Alertmanager on this host, so n8n's failed workflows and reminders aren't mailed; list monitoring here to mail them";

      axon.persist.state.directories = [
        {
          directory = state;
          mode = "0700";
        }
      ];

      axon.services.automation = {
        units = [
          "n8n"
          "n8n-import"
        ];
        route.port = 5678;
        dashboard = {
          name = "n8n";
          group = "Code";
          description = "Workflows";
          icon = "n8n.svg";
          monitor = "/healthz";
        };
        backup.paths = [ state ];
      };
    };
}
