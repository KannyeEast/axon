# Recyclarr applies .config/recyclarr/recyclarr.yml (and settings.yml for own formats) to Radarr
# and Sonarr on change and nightly, as TRaSH's guides move on; keys as !env_var <APP>_API_KEY.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        hasSecret
        host
        services
        user
        ;
      state = "/var/lib/recyclarr";
      names = [
        "radarr"
        "sonarr"
      ];
      dirs = map (home: "${home}/.config/recyclarr") config.axon.dotfiles;
      secret = name: services.${name}.apiKey;
      # recyclarr.yml reads both keys; one unset fails the whole file
      missing = lib.filter (name: !hasSecret (secret name)) names;

      sync = pkgs.writeShellApplication {
        name = "recyclarr-sync";
        runtimeInputs = [ pkgs.recyclarr ];
        text = ''
          ${lib.concatMapStrings (app: ''
            ${lib.toUpper app}_API_KEY=$(<"$CREDENTIALS_DIRECTORY/${app}")
            export ${lib.toUpper app}_API_KEY
          '') names}
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
    lib.mkIf (config.axon.volumes ? media) {
      # ── units ────────
      systemd.services.recyclarr = lib.mkIf (missing == [ ]) {
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
          StateDirectoryMode = "0700";
          LoadCredential = map (app: "${app}:${config.sops.secrets.${secret app}.path}") names;
          ExecStart = lib.getExe sync;
          Environment = "RECYCLARR_CONFIG_DIR=${state}";
        };
      };
      systemd.timers.recyclarr = lib.mkIf (missing == [ ]) {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "03:00";
          Persistent = true;
        };
      };
      systemd.paths.recyclarr = lib.mkIf (missing == [ ]) {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = lib.concatMap (dir: [
          "${dir}/recyclarr.yml"
          "${dir}/settings.yml"
        ]) dirs;
      };

      # ── data ────────
      # which custom formats it made, so it can remove the ones a file no longer lists
      axon.persist.state.directories = lib.mkIf (missing == [ ]) [ state ];

      # ── checks ────────
      warnings =
        lib.optional (missing != [ ])
          "hosts/${host.name}/secrets.json: no ${
            lib.concatMapStringsSep ", " secret missing
          }, so Recyclarr doesn't run; add them with `just secrets ${host.name}`";
    };
}
