# restic, one repository per target. What gets backed up is whatever services declare in
# axon.services.<name>.backup.paths; targets (repository, schedule, password, env) live in
# secrets.json under backup.<name>. With no targets it does nothing.
{ lib, ... }:
{
  flake.modules.nixos.backup =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host;
      ph = config.sops.placeholder;

      # targets are data in secrets.json: backup.<name>.{password, repository_unencrypted, schedule_unencrypted, env}
      targets = config.axon.secrets.backup or { };

      # sops leaves values with this suffix unencrypted, so Nix can read them at eval
      rmSuffix = lib.mapAttrs' (
        name: value: lib.nameValuePair (lib.removeSuffix "_unencrypted" name) value
      );

      envOf = data: data.env or { };
      secretEnv = lib.filterAttrs (key: _: !lib.hasSuffix "_unencrypted" key);

      mkEnv =
        name: env:
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            key: value:
            if lib.hasSuffix "_unencrypted" key then
              "${lib.removeSuffix "_unencrypted" key}='${value}'"
            else
              "${key}='${ph."backup/${name}/env/${key}"}'"
          ) env
        );

      backups = lib.filter (service: service.backup.paths != [ ]) (lib.attrValues config.axon.services);

      paths = lib.unique (lib.concatMap (service: service.backup.paths) backups);
      exclude = lib.unique (lib.concatMap (service: service.backup.exclude) backups);
    in
    {
      warnings =
        lib.optional (targets == { })
          "hosts/${host.name}/secrets.json: the backup feature has no targets, so nothing is backed up; add backup.<name> with `just secrets ${host.name}`";

      sops.secrets = lib.concatMapAttrs (
        name: data:
        {
          "backup/${name}/password" = { };
        }
        // lib.concatMapAttrs (key: _: { "backup/${name}/env/${key}" = { }; }) (secretEnv (envOf data))
      ) targets;

      sops.templates = lib.mapAttrs' (
        name: data: lib.nameValuePair "restic-${name}.env" { content = mkEnv name (envOf data); }
      ) (lib.filterAttrs (_: data: envOf data != { }) targets);

      axon.persist.state.directories = [
        "/root/.cache/restic"
      ];

      environment.systemPackages = [
        pkgs.restic
      ];

      services.restic.backups = lib.mapAttrs (
        name: data:
        let
          target = rmSuffix data;
        in
        {
          initialize = true;
          inherit (target) repository;
          passwordFile = config.sops.secrets."backup/${name}/password".path;

          inherit paths exclude;
          pruneOpts = [
            "--keep-daily 7"
            "--keep-weekly 5"
            "--keep-monthly 12"
            "--keep-yearly 75"
          ];

          timerConfig = {
            OnCalendar = target.schedule;
            RandomizedDelaySec = "20m";
            Persistent = true;
          };
        }
        // lib.optionalAttrs (lib.hasPrefix "/" target.repository) {
          checkOpts = [ "--read-data-subset=5%" ];
        }
        // lib.optionalAttrs (envOf data != { }) {
          environmentFile = config.sops.templates."restic-${name}.env".path;
        }
      ) targets;

      systemd.services = lib.concatMapAttrs (
        name: data:
        lib.optionalAttrs (lib.hasPrefix "/" (rmSuffix data).repository) {
          "restic-backups-${name}".unitConfig.RequiresMountsFor = [ (rmSuffix data).repository ];
        }
      ) targets;
    };
}
