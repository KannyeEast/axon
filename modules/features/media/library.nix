# Jellyfin at jellyfin.<domain>: movies and shows from the media space.
# Reach: public, its own login.
# In its UI only: libraries, users, encoding, plugins and their settings, backed up with its state.
{ lib, ... }:
{
  flake.modules.nixos.media =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host;
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
      # the library, shared with the downloads feature's apps
      axon.spaces.media = {
        group = "media";
        mode = "2775";
        units = [ "jellyfin" ];
      };

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
