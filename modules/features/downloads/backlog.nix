# A nightly search in Radarr and Sonarr for what is monitored and missing, and for what is below
# its profile's cutoff. They never search old releases on their own: a search that failed (an
# indexer's limit) stays failed, and a fallback (English) is replaced only when a search finds the
# better one. Prowlarr's per-indexer query limit keeps it within the indexers' plans.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      apps = {
        radarr = {
          inherit (config.services.radarr) dataDir;
          port = 7878;
          commands = [
            "MissingMoviesSearch"
            "CutoffUnmetMoviesSearch"
          ];
        };
        sonarr = {
          inherit (config.services.sonarr) dataDir;
          port = 8989;
          commands = [
            "MissingEpisodeSearch"
            "CutoffUnmetEpisodeSearch"
          ];
        };
      };

      search = pkgs.writeShellApplication {
        name = "backlog-search";
        runtimeInputs = [
          pkgs.curl
          pkgs.gnused
        ];
        # the API key is the one the app made itself, read from its config.xml; a failed call
        # fails the unit, so it is reported
        text =
          "failed=0\n"
          + lib.concatStrings (
            lib.mapAttrsToList (name: app: ''
              key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' ${app.dataDir}/config.xml 2>/dev/null || true)
              if [ -z "$key" ]; then
                echo "${name}: no API key in ${app.dataDir}/config.xml yet, skipped"
              else
                ${lib.concatMapStrings (command: ''
                  if curl -fsS -o /dev/null -H "X-Api-Key: $key" -H "Content-Type: application/json" \
                    -d '{"name": "${command}"}' http://127.0.0.1:${toString app.port}/api/v3/command; then
                    echo "${name}: ${command} started"
                  else
                    echo "${name}: ${command} failed" >&2
                    failed=1
                  fi
                '') app.commands}
              fi
            '') apps
          )
          + "exit $failed\n";
      };
    in
    lib.mkIf (config.axon.volumes ? media) {
      systemd.services.backlog-search = {
        description = "Search Radarr and Sonarr for missing and below-cutoff items";
        after = [
          "radarr.service"
          "sonarr.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe search;
        };
      };
      systemd.timers.backlog-search = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "03:30";
      };
    };
}
