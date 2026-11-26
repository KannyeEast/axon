# Decluttarr clears what hangs in Radarr's and Sonarr's queues, blocklists it and searches again, as
# .config/decluttarr/config.yaml says (keys as !ENV RADARR_API_KEY, SONARR_API_KEY). No state.
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
        ;
      # it reads ./config/config.yaml and writes ./logs
      runtime = "/run/decluttarr";
      file = "${home}/.config/decluttarr/config.yaml";
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

      secrets = {
        radarr = services.radarr.apiKey;
        sonarr = services.sonarr.apiKey;
      };
      missing = lib.filter (key: !hasSecret key) (lib.attrValues secrets);
    in
    lib.mkIf (config.axon.onDisk ? media) {
      # ── units ────────
      systemd.services = lib.mkIf (missing == [ ]) {
        decluttarr = {
          description = "Clear stuck downloads from Radarr's and Sonarr's queues";
          wantedBy = [ "multi-user.target" ];
          after = [
            "radarr.service"
            "sonarr.service"
          ];
          unitConfig.ConditionPathExists = file;
          serviceConfig = {
            DynamicUser = true;
            RuntimeDirectory = "decluttarr";
            WorkingDirectory = runtime;
            EnvironmentFile = config.sops.templates."decluttarr.env".path;
            # its DynamicUser can't read the user's 0700 home; the manager mounts the file in as root
            BindReadOnlyPaths = [ "-${file}:${runtime}/config/config.yaml" ];
            ExecStart = "${lib.getExe python} ${src}/main.py";
            Restart = "on-failure";
          };
        };
        decluttarr-config = {
          description = "Restart Decluttarr on a new config";
          serviceConfig = {
            Type = "oneshot";
            # also starts it when the file appears after it found none
            ExecStart = "${pkgs.systemd}/bin/systemctl restart decluttarr.service";
          };
        };
      };
      systemd.paths.decluttarr-config = lib.mkIf (missing == [ ]) {
        wantedBy = [ "paths.target" ];
        pathConfig.PathChanged = [ file ];
      };

      # ── secrets ────────
      sops.secrets = lib.mkIf (missing == [ ]) (lib.genAttrs (lib.attrValues secrets) (_: { }));
      sops.templates."decluttarr.env" = lib.mkIf (missing == [ ]) {
        content = lib.concatStrings (
          lib.mapAttrsToList (
            app: key: "${lib.toUpper app}_API_KEY=${config.sops.placeholder.${key}}\n"
          ) secrets
        );
      };

      # ── checks ────────
      warnings =
        lib.optional (missing != [ ])
          "hosts/${host.name}/secrets.json: no ${lib.concatStringsSep ", " missing}, so Decluttarr doesn't run; add them with `just secrets ${host.name}`";
    };
}
