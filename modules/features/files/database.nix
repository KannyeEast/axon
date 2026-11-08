# The Postgres that Nextcloud, Immich and Paperless share; each creates its own database in it.
# It runs on the system SSD, so Nextcloud's nightly dump goes on the data volume, where a host has
# one: a dump next to its database is lost with it. Immich and Paperless write their own.
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, ... }:
    let
      inherit (config.axon) volumes;
      dumps = "${volumes.data or "/var/backup"}/postgresql";
    in
    lib.mkIf (config.axon.host.class == "server") {
      services.postgresqlBackup = {
        enable = true;
        location = dumps;
        databases = [ "nextcloud" ];
      };

      # the dump lives on a data disk that may be missing at boot (nofail): never write to root instead
      systemd.services.postgresqlBackup-nextcloud.unitConfig.RequiresMountsFor = [ dumps ];

      axon.persist.state.directories = [
        {
          directory = "/var/lib/postgresql";
          user = "postgres";
          group = "postgres";
          mode = "0750";
        }
      ]
      ++ lib.optional (!volumes ? data) dumps;

      axon.services.database.backup.paths = [ dumps ];
    };
}
