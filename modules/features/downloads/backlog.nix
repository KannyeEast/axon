# A nightly search in Radarr and Sonarr for what is monitored and missing, for what is below its
# profile's quality cutoff, and for files below the profile's custom format cutoff (a fallback,
# e.g. English where the profile wants German). They never search old releases on their own, and
# their cutoff-unmet search ignores custom format scores. A few of the last kind per night, picked
# at random, and Prowlarr's per-indexer query limit keep it within the indexers' plans.
{ lib, ... }:
{
  flake.modules.nixos.downloads =
    { config, pkgs, ... }:
    let
      # files below their profile's format cutoff searched per night, per app
      upgrades = 50;

      apps = {
        radarr = {
          inherit (config.services.radarr) dataDir;
          port = 7878;
          commands = [
            "MissingMoviesSearch"
            "CutoffUnmetMoviesSearch"
          ];
          # movie ids whose file scores below its profile's cutoffFormatScore
          below = ''
            api movie | jq -c '.[] | select(.monitored and .hasFile) | {id, qualityProfileId}' |
              while read -r movie; do
                id=$(jq -r .id <<<"$movie")
                cutoff=$(jq -r --argjson p "$(jq .qualityProfileId <<<"$movie")" \
                  '.[] | select(.id == $p) | .cutoffFormatScore' <<<"$profiles")
                api "moviefile?movieId=$id" |
                  jq -r --argjson c "$cutoff" --arg id "$id" '.[] | select(.customFormatScore < $c) | $id'
              done
          '';
          upgrade = ''{"name": "MoviesSearch", "movieIds": $ids}'';
        };
        sonarr = {
          inherit (config.services.sonarr) dataDir;
          port = 8989;
          commands = [
            "MissingEpisodeSearch"
            "CutoffUnmetEpisodeSearch"
          ];
          # monitored episode ids whose file scores below its series' profile's cutoffFormatScore
          below = ''
            api series | jq -c '.[] | select(.monitored) | {id, qualityProfileId}' |
              while read -r series; do
                id=$(jq -r .id <<<"$series")
                cutoff=$(jq -r --argjson p "$(jq .qualityProfileId <<<"$series")" \
                  '.[] | select(.id == $p) | .cutoffFormatScore' <<<"$profiles")
                low=$(api "episodefile?seriesId=$id" |
                  jq -c --argjson c "$cutoff" '[.[] | select(.customFormatScore < $c) | .id]')
                api "episode?seriesId=$id" |
                  jq -r --argjson low "$low" '.[] | select(.monitored and .hasFile and (.episodeFileId as $f | $low | index($f))) | .id'
              done
          '';
          upgrade = ''{"name": "EpisodeSearch", "episodeIds": $ids}'';
        };
      };

      search = pkgs.writeShellApplication {
        name = "backlog-search";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gnused
          pkgs.jq
        ];
        # the API key is the one the app made itself, read from its config.xml; a failed call
        # fails the unit, so it is reported
        text = ''
          failed=0
          post() {
            if curl -fsS -o /dev/null -H "X-Api-Key: $key" -H "Content-Type: application/json" \
              -d "$2" "$base/command"; then
              echo "$1 started"
            else
              echo "$1 failed" >&2
              failed=1
            fi
          }
          api() { curl -fsS -H "X-Api-Key: $key" "$base/$1"; }
        ''
        + lib.concatStrings (
          lib.mapAttrsToList (name: app: ''
            key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' ${app.dataDir}/config.xml 2>/dev/null || true)
            base=http://127.0.0.1:${toString app.port}/api/v3
            if [ -z "$key" ]; then
              echo "${name}: no API key in ${app.dataDir}/config.xml yet, skipped"
            else
              ${lib.concatMapStrings (command: ''
                post "${name}: ${command}" '{"name": "${command}"}'
              '') app.commands}
              if profiles=$(api qualityprofile) && below=$(${app.below}); then
                ids=$(shuf <<<"$below" | head -n ${toString upgrades} | jq -s -c 'map(tonumber)')
                if [ "$ids" != "[]" ]; then
                  post "${name}: format upgrade of $(jq length <<<"$ids") of $(grep -c . <<<"$below")" \
                    "$(jq -n -c --argjson ids "$ids" '${app.upgrade}')"
                fi
              else
                echo "${name}: files below the format cutoff couldn't be listed" >&2
                failed=1
              fi
            fi
          '') apps
        )
        + "exit $failed\n";
      };
    in
    lib.mkIf (config.axon.volumes ? media) {
      systemd.services.backlog-search = {
        description = "Search Radarr and Sonarr for missing items and upgrades";
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
