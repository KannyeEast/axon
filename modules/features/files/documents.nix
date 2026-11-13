# Paperless-ngx at docs.<domain> on servers: scanned documents, OCR'd and filed. Tailnet only, its
# own login; without a gateway on this host it stays on localhost. Documents on the data volume
# (or in the state folder without one), database in the shared Postgres. The nightly export
# (originals, OCR'd copies, tags and metadata) is what gets backed up.
# First account by hand after install: sudo paperless-manage createsuperuser
{ lib, ... }:
{
  flake.modules.nixos.files =
    { config, ... }:
    let
      inherit (config.axon) routed services;
      data = config.axon.spaces.paperless.path;
      port = 28981;
    in
    lib.mkIf (config.axon.host.class == "server") {
      services.paperless = {
        enable = true;
        inherit port;
        domain = if routed then services.docs.route.host else null;
        mediaDir = "${data}/media";
        consumptionDir = "${data}/consume";
        database.createLocally = true;
        # every language: a shorter list rebuilds tesseract, ocrmypdf and paperless from source
        tesseractLanguages = null;
        settings = {
          PAPERLESS_OCR_LANGUAGE = "deu+eng";
          PAPERLESS_FILENAME_FORMAT = "{{ correspondent }}/{{ created_year }}/{{ title }}";
        };
        exporter = {
          enable = true;
          directory = "${data}/export";
        };
      };

      axon.spaces.paperless = {
        user = "paperless";
        group = "paperless";
        units = [
          "paperless-consumer"
          "paperless-task-queue"
          "paperless-web"
          "paperless-exporter"
        ];
      };

      axon.persist.state.directories = [
        {
          directory = "/var/lib/paperless";
          user = "paperless";
          group = "paperless";
          mode = "0750";
        }
        "/var/lib/redis-paperless"
      ];

      axon.services.docs = {
        route = {
          inherit port;
          access = "open"; # Paperless's own login
        };
        dashboard = {
          name = "Paperless";
          group = "Files";
          description = "Documents";
          icon = "paperless-ngx.svg";
          widget.type = "paperlessngx";
          key = true;
        };
        backup.paths = [ "${data}/export" ];
      };
    };
}
