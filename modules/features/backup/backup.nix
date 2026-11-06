# restic, one repository per target. What gets backed up is whatever services declare in
# axon.services.<name>.backup.paths; targets (repository, schedule, password, env) live in
# secrets.json under backup.<name>. With no targets it does nothing.
{ lib, ... }:
let
  inherit (lib)
    attrValues
    concatMap
    concatMapAttrs
    concatStringsSep
    filter
    filterAttrs
    hasPrefix
    hasSuffix
    mapAttrs
    mapAttrs'
    mapAttrsToList
    nameValuePair
    optional
    optionalAttrs
    removeSuffix
    unique
    ;
in
{
  flake.modules.nixos.backup =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host;
      ph = config.sops.placeholder;

      # targets are data in secrets.json: backup.<name>.{password, repository_unencrypted, schedule_unencrypted, env}
      targets = config.axon.secrets.backup or { };

      # sops-nix can also leave values unencrypted with this suffix; useful when values need to be read at eval
      rmSuffix = mapAttrs' (name: value: nameValuePair (removeSuffix "_unencrypted" name) value);

      envOf = data: data.env or { };
      secretEnv = filterAttrs (key: _: !hasSuffix "_unencrypted" key);

      mkEnv =
        name: env:
        concatStringsSep "\n" (
          mapAttrsToList (
            key: value:
            if hasSuffix "_unencrypted" key then
              "${removeSuffix "_unencrypted" key}='${value}'"
            else
              "${key}='${ph."backup/${name}/env/${key}"}'"
          ) env
        );

      backups = filter (service: service.backup.paths != [ ]) (attrValues config.axon.services);

      paths = unique (concatMap (service: service.backup.paths) backups);
      exclude = unique (concatMap (service: service.backup.exclude) backups);
    in
    {
      warnings =
        optional (targets == { })
          "hosts/${host.name}/secrets.json: the backup feature has no targets, so nothing is backed up; add backup.<name> with `just secrets ${host.name}`";

      sops.secrets = concatMapAttrs (
        name: data:
        {
          "backup/${name}/password" = { };
        }
        // concatMapAttrs (key: _: { "backup/${name}/env/${key}" = { }; }) (secretEnv (envOf data))
      ) targets;

      sops.templates = mapAttrs' (
        name: data: nameValuePair "restic-${name}.env" { content = mkEnv name (envOf data); }
      ) (filterAttrs (_: data: envOf data != { }) targets);

      axon.persist.directories = [
        "/root/.cache/restic"
      ];

      environment.systemPackages = [
        pkgs.restic
        pkgs.rclone
      ];

      services.restic.backups = mapAttrs (
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
        // optionalAttrs (hasPrefix "/" target.repository) {
          checkOpts = [ "--read-data-subset=5%" ];
        }
        // optionalAttrs (envOf data != { }) {
          environmentFile = config.sops.templates."restic-${name}.env".path;
        }
      ) targets;

      systemd.services = concatMapAttrs (
        name: data:
        optionalAttrs (hasPrefix "/" (rmSuffix data).repository) {
          "restic-backups-${name}".unitConfig.RequiresMountsFor = [ (rmSuffix data).repository ];
        }
      ) targets;
    };
}
