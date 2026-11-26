# Recyclarr applies .config/recyclarr/recyclarr.yml (and settings.yml for own formats) to Radarr
# and Sonarr on change and nightly, as TRaSH's guides move on; keys as !env_var <APP>_API_KEY.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      inherit (config.axon)
        hasSecret
        home
        host
        services
        user
        ;
      state = "/var/lib/recyclarr";
      dir = "${home}/.config/recyclarr";
      names = [
        "radarr"
        "sonarr"
      ];
      secret = name: services.${name}.apiKey;
      # recyclarr.yml reads both keys; one unset fails the whole file
      missing = lib.filter (name: !hasSecret (secret name)) names;
    in
    lib.mkIf (config.axon.onDisk ? media) {
      # ── units ────────
      # services.recyclarr takes its config as Nix and runs with ProtectHome=true, so it can't read
      # the dotfile
      systemd.services.recyclarr = lib.mkIf (missing == [ ]) {
        description = "Apply the Radarr and Sonarr profiles from the checkout";
        after = [
          "radarr.service"
          "sonarr.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        unitConfig.ConditionPathExists = "${dir}/recyclarr.yml";
        serviceConfig = {
          Type = "oneshot";
          User = user.name;
          StateDirectory = "recyclarr";
          StateDirectoryMode = "0700";
          EnvironmentFile = config.sops.templates."recyclarr.env".path;
          Environment = "RECYCLARR_CONFIG_DIR=${state}";
          # it reads settings.yml from its config folder, where its state lives. Without one it
          # writes a default there, which a dangling link would put into the home
          ExecStartPre = "${pkgs.runtimeShell} -c 'if [ -e ${dir}/settings.yml ]; then ln -sfn ${dir}/settings.yml ${state}/settings.yml; else rm -f ${state}/settings.yml; fi'";
          ExecStart = "${lib.getExe pkgs.recyclarr} sync --config ${dir}/recyclarr.yml";
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
        pathConfig.PathChanged = [
          "${dir}/recyclarr.yml"
          "${dir}/settings.yml"
        ];
      };

      # ── secrets ────────
      sops.secrets = lib.mkIf (missing == [ ]) (lib.genAttrs (map secret names) (_: { }));
      sops.templates."recyclarr.env" = lib.mkIf (missing == [ ]) {
        content = lib.concatMapStrings (
          name: "${lib.toUpper name}_API_KEY=${config.sops.placeholder.${secret name}}\n"
        ) names;
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
