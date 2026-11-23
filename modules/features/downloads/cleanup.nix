# Decluttarr clears what hangs in Radarr's and Sonarr's queues, blocklists it and searches again, as
# .config/decluttarr/config.yaml says (keys as !ENV RADARR_API_KEY, SONARR_API_KEY). No state.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        hasSecret
        host
        services
        ;
      # it reads ./config/config.yaml and writes ./logs
      runtime = "/run/decluttarr";
      files = map (home: "${home}/.config/decluttarr/config.yaml") config.axon.dotfiles;
      secrets = {
        radarr = services.radarr.apiKey;
        sonarr = services.sonarr.apiKey;
      };
      missing = lib.filter (key: !hasSecret key) (lib.attrValues secrets);

      src = pkgs.fetchFromGitHub {
        owner = "ManiMatter";
        repo = "decluttarr";
        # v2.2.0
        rev = "193725099875819b48c9a4f6316253b4051944b2";
        hash = "sha256-36XOEnNE5aJg9QkVK2nI8xK3RiugNH3Xjhswt3dhj+s=";
      };
      python = pkgs.python3.withPackages (ps: [
        ps.packaging
        ps.python-dateutil
        ps.pyyaml-env-tag
        ps.requests
        ps.watchdog
      ]);

      # its DynamicUser can't read the checkout under the user's 0700 home: root copies the file
      # here first
      copy = pkgs.writeShellApplication {
        name = "decluttarr-copy-config";
        text = ''
          for file in ${lib.escapeShellArgs files}; do
            if [ -e "$file" ]; then
              install -D -m 0444 "$file" ${runtime}/config/config.yaml
              exit 0
            fi
          done
        '';
      };
      run = pkgs.writeShellApplication {
        name = "decluttarr";
        text = ''
          ${lib.concatMapStrings (app: ''
            ${lib.toUpper app}_API_KEY=$(<"$CREDENTIALS_DIRECTORY/${app}")
            export ${lib.toUpper app}_API_KEY
          '') (lib.attrNames secrets)}
          if [ -e config/config.yaml ]; then
            exec ${lib.getExe python} ${src}/main.py
          fi
          echo "no .config/decluttarr/config.yaml in the checkout, nothing to do"
        '';
      };
    in
    lib.mkIf (config.axon.volumes ? media) (
      lib.mkMerge [
        {
          warnings =
            lib.optional (missing != [ ])
              "hosts/${host.name}/secrets.json: no ${lib.concatStringsSep ", " missing}, so Decluttarr doesn't run; add them with `just secrets ${host.name}`";
        }

        (lib.mkIf (missing == [ ]) {
          systemd.services.decluttarr = {
            description = "Clear stuck downloads from Radarr's and Sonarr's queues";
            wantedBy = [ "multi-user.target" ];
            after = [
              "radarr.service"
              "sonarr.service"
            ];
            serviceConfig = {
              DynamicUser = true;
              RuntimeDirectory = "decluttarr";
              WorkingDirectory = runtime;
              LoadCredential = lib.mapAttrsToList (app: key: "${app}:${config.sops.secrets.${key}.path}") secrets;
              ExecStartPre = "+${lib.getExe copy}";
              ExecStart = lib.getExe run;
              Restart = "on-failure";
            };
          };
          systemd.paths.decluttarr-config = {
            wantedBy = [ "paths.target" ];
            pathConfig.PathChanged = files;
          };
          systemd.services.decluttarr-config = {
            description = "Restart Decluttarr on a new config";
            serviceConfig = {
              Type = "oneshot";
              # also starts it when the file appears after it found none
              ExecStart = "${pkgs.systemd}/bin/systemctl restart decluttarr.service";
            };
          };
        })
      ]
    );
}
