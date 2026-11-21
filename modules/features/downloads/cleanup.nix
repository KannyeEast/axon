# Decluttarr clears what hangs in Radarr's and Sonarr's queues (a download that can't be imported,
# a failed one, one whose item is gone), blocklists it and lets the app search again. Its settings
# are .config/decluttarr/config.yaml from the checkout (hosts/<name>/home wins over home/), read on
# start and again when the file changes; it reads the keys as !ENV RADARR_API_KEY and
# SONARR_API_KEY.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host repo user;
      state = "/var/lib/decluttarr";
      files = map (home: "${home}/.config/decluttarr/config.yaml") [
        "${repo}/hosts/${host.name}/home"
        "${repo}/home"
      ];
      keys = lib.filterAttrs (_: key: lib.hasAttrByPath (lib.splitString "/" key) config.axon.secrets) {
        radarr = "dashboard/radarr/key";
        sonarr = "dashboard/sonarr/key";
      };

      src = pkgs.fetchFromGitHub {
        owner = "ManiMatter";
        repo = "decluttarr";
        rev = "0c4851d19514f570eb6a5dd026b51310ee07aaee";
        hash = "sha256-r783B1NaEmA4wCxawU+OppNIc6mubckXYzLssczEVZU=";
      };
      python = pkgs.python3.withPackages (ps: [
        ps.demjson3
        ps.packaging
        ps.python-dateutil
        ps.pyyaml-env-tag
        ps.requests
        ps.watchdog
      ]);

      run = pkgs.writeShellApplication {
        name = "decluttarr";
        text = ''
          ${lib.concatMapStrings (app: ''
            ${lib.toUpper app}_API_KEY=$(<"$CREDENTIALS_DIRECTORY/${app}")
            export ${lib.toUpper app}_API_KEY
          '') (lib.attrNames keys)}
          # it reads ./config/config.yaml
          mkdir -p config
          for file in ${lib.escapeShellArgs files}; do
            if [ -e "$file" ]; then
              ln -sfn "$file" config/config.yaml
              exec ${lib.getExe python} ${src}/main.py
            fi
          done
          echo "no .config/decluttarr/config.yaml in the checkout, nothing to do"
        '';
      };
    in
    lib.mkIf (config.axon.volumes ? media && keys ? radarr && keys ? sonarr) {
      systemd.services.decluttarr = {
        description = "Clear stuck downloads from Radarr's and Sonarr's queues";
        wantedBy = [ "multi-user.target" ];
        after = [
          "radarr.service"
          "sonarr.service"
        ];
        serviceConfig = {
          User = user.name;
          StateDirectory = "decluttarr";
          WorkingDirectory = state;
          LoadCredential = lib.mapAttrsToList (app: key: "${app}:${config.sops.secrets.${key}.path}") keys;
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
    };
}
