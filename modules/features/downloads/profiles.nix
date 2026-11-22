# Radarr's and Sonarr's quality profiles and custom formats as a file: Recyclarr applies
# .config/recyclarr/recyclarr.yml (and settings.yml, for formats of our own) from the checkout
# (hosts/<name>/home wins over home/) when it changes and nightly, as TRaSH's guides move on. The
# file reads the keys as !env_var RADARR_API_KEY and SONARR_API_KEY.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon) user;
      state = "/var/lib/recyclarr";
      dirs = map (home: "${home}/.config/recyclarr") config.axon.dotfiles;
      secret = name: "dashboard/${name}/key";
      hasKey = name: lib.hasAttrByPath (lib.splitString "/" (secret name)) config.axon.secrets;
      apps = lib.filter hasKey [
        "radarr"
        "sonarr"
      ];

      sync = pkgs.writeShellApplication {
        name = "recyclarr-sync";
        runtimeInputs = [ pkgs.recyclarr ];
        text = ''
          ${lib.concatMapStrings (app: ''
            ${lib.toUpper app}_API_KEY=$(<"$CREDENTIALS_DIRECTORY/${app}")
            export ${lib.toUpper app}_API_KEY
          '') apps}
          for dir in ${lib.escapeShellArgs dirs}; do
            if [ -e "$dir/recyclarr.yml" ]; then
              # it keeps its state next to settings.yml, so that one is linked in
              if [ -e "$dir/settings.yml" ]; then
                ln -sfn "$dir/settings.yml" ${state}/settings.yml
              else
                rm -f ${state}/settings.yml
              fi
              exec recyclarr sync --config "$dir/recyclarr.yml" "$@"
            fi
          done
          echo "no .config/recyclarr/recyclarr.yml in the checkout, nothing to apply"
        '';
      };
    in
    lib.mkIf (config.axon.volumes ? media && apps != [ ]) {
      systemd.services.recyclarr = {
        description = "Apply the Radarr and Sonarr profiles from the checkout";
        after = [
          "radarr.service"
          "sonarr.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = user.name;
          StateDirectory = "recyclarr";
          LoadCredential = map (app: "${app}:${config.sops.secrets.${secret app}.path}") apps;
          ExecStart = lib.getExe sync;
          Environment = "RECYCLARR_CONFIG_DIR=${state}";
        };
      };
      systemd.timers.recyclarr = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "03:00";
          Persistent = true;
        };
      };
      systemd.paths.recyclarr = {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = lib.concatMap (dir: [
          "${dir}/recyclarr.yml"
          "${dir}/settings.yml"
        ]) dirs;
      };

      # which custom formats it made, so it can remove the ones a file no longer lists
      axon.persist.state.directories = [
        {
          directory = state;
          user = user.name;
          mode = "0700";
        }
      ];
    };
}
