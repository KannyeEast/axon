# Jellyfin at jellyfin.<domain>: movies and shows from the media volume.
# Reach: public, its own login.
# In its UI only: libraries, users, encoding, plugins and their settings, backed up with its state.
{ lib, ... }:
{
  flake.modules.nixos.media =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host volumes;
    in
    lib.mkIf (host.class == "server") {
      # ── service ────────
      services.jellyfin = {
        enable = true;
        group = "media";
      };
      users.groups.media = { };

      # ── units ────────
      systemd.services.jellyfin = {
        # the library is on a data disk that may be missing at boot (nofail)
        unitConfig.RequiresMountsFor = lib.optional (volumes ? media) volumes.media;
        # scheduled tasks and chatty plugins log their routine at info
        serviceConfig.ExecStartPre = [
          # as jellyfin, making its config folder where a new persist mount hid tmpfiles' one
          "${lib.getExe' pkgs.coreutils "install"} -D -m 0644 ${
            pkgs.writeText "logging.json" (
              lib.toJSON {
                Serilog.MinimumLevel.Override = lib.genAttrs [
                  "Emby.Server.Implementations.ScheduledTasks.TaskManager"
                  "Jellyfin.Plugin.PlaybackReporting"
                  "Jellyfin.Plugin.JellyfinEnhanced"
                ] (_: "Warning");
              }
            )
          } ${config.services.jellyfin.configDir}/logging.json"
        ];
      };

      # ── data ────────
      axon.persist.state.directories =
        map
          (directory: {
            inherit directory;
            user = "jellyfin";
            group = "media";
            mode = "0700";
          })
          [
            "/var/lib/jellyfin"
            # image cache and transcodes; rebuilt after every boot otherwise
            config.services.jellyfin.cacheDir
          ];

      # ── registration ────────
      axon.services.jellyfin = {
        units = [ "jellyfin" ];
        # its log entries' first line; a stack trace follows it
        logStart = "^\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\] \\[";
        route = {
          port = 8096;
          public = true;
        };
        dashboard = {
          name = "Jellyfin";
          order = 1;
          group = "Media";
          description = "Movies and shows";
          icon = "jellyfin.svg";
          space = "media";
          widget = {
            type = "jellyfin";
            version = 2;
            enableBlocks = true;
            enableNowPlaying = false;
          };
          key = true;
        };
        backup.paths = [ "/var/lib/jellyfin" ];
      };
    };
}
