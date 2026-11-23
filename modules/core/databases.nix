# Contract: axon.databases. The Postgres databases this host's services keep, each created by its
# service's module. With any listed, the host runs its own Postgres and dumps each nightly to the
# data volume where there is one: a dump beside its database is lost with it.
{ lib, ... }:
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) databases volumes;
      dumps = "${volumes.data or "/var/backup"}/postgresql";
    in
    {
      options.axon.databases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Names of the Postgres databases this host's services keep, each dumped nightly.";
      };

      config = lib.mkIf (databases != [ ]) {
        services.postgresql = {
          enable = true;
          # on by default: two lines for each checkpoint, every few minutes
          settings.log_checkpoints = false;
        };

        services.postgresqlBackup = {
          enable = true;
          location = dumps;
          inherit databases;
        };

        # the data disk may be missing at boot (nofail): never write the dumps to root instead
        systemd.services = lib.genAttrs (map (name: "postgresqlBackup-${name}") databases) (_: {
          unitConfig.RequiresMountsFor = [ dumps ];
        });
        systemd.timers = lib.genAttrs (map (name: "postgresqlBackup-${name}") databases) (_: {
          timerConfig.Persistent = true;
        });

        axon.persist.state.directories = [
          {
            directory = "/var/lib/postgresql";
            user = "postgres";
            group = "postgres";
            mode = "0750";
          }
        ]
        ++ lib.optional (!volumes ? data) dumps;

        axon.services.postgres = {
          units = [
            "postgresql"
            "postgresql-setup"
          ]
          ++ map (name: "postgresqlBackup-${name}") databases;
          backup.paths = [ dumps ];
        };
      };
    };
}
