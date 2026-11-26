# Contract: axon.databases. The Postgres databases this host's services keep, each created by its
# service's module. With any listed, the host runs its own Postgres in the databases space and dumps
# each nightly to the backups space, best on another disk: a dump beside the data is lost with it.
{ lib, ... }:
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) databases;
      data = "${config.axon.spaces.databases.path}/${config.services.postgresql.package.psqlSchema}";
      dumps = "${config.axon.spaces.backups.path}/postgresql";
      units = map (name: "postgresqlBackup-${name}") databases;
    in
    {
      # ── contract ────────
      options.axon.databases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Names of the Postgres databases this host's services keep, each dumped nightly.";
      };

      config = lib.mkIf (databases != [ ]) {
        # ── settings ────────
        services.postgresql = {
          enable = true;
          dataDir = data;
          # on by default: two lines for each checkpoint, every few minutes
          settings.log_checkpoints = false;
        };

        services.postgresqlBackup = {
          enable = true;
          location = dumps;
          inherit databases;
        };

        # ── units ────────
        systemd.timers = lib.genAttrs units (_: {
          timerConfig.Persistent = true;
        });

        # ── data ────────
        axon.spaces.databases = {
          user = "postgres";
          group = "postgres";
          mode = "0750";
          units = [
            "postgresql"
            "postgresql-setup"
          ];
        };

        # a data directory of its own gets no StateDirectory from its module
        axon.folders.${data} = {
          user = "postgres";
          group = "postgres";
          mode = "0750";
          units = [
            "postgresql"
            "postgresql-setup"
          ];
        };

        axon.spaces.backups = { inherit units; };

        # its module's tmpfiles rule may run before the space's mount at boot
        axon.folders.${dumps} = {
          user = "postgres";
          group = "root";
          mode = "0700";
          inherit units;
        };

        # ── registration ────────
        axon.services.postgres = {
          units = [
            "postgresql"
            "postgresql-setup"
          ]
          ++ units;
          backup.paths = [ dumps ];
        };
      };
    };
}
