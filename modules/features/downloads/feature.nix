{
  axon.features.downloads = {
    description = "qBittorrent locked into the VPN and SABnzbd for Usenet; with a media volume, also Seerr and the *arr stack to fill the library";
    classes = [ "server" ];
    requires = [ "vpn" ];
    metrics = {
      sabnzbd.port = 9387;
      sonarr = {
        port = 9707;
        volume = "media";
      };
      radarr = {
        port = 9708;
        volume = "media";
      };
      prowlarr = {
        port = 9710;
        volume = "media";
      };
    };
    alerts = [
      {
        alert = "DownloadsStalled";
        expr = "sabnzbd_queue_length > 0 and sabnzbd_paused == 0 and sabnzbd_speed_bps == 0";
        for = "2h";
        annotations.summary = "{{ $value }} queued, nothing downloading";
      }
      # a hung post-processing keeps it paused, as does a pause that was forgotten; a full media
      # space pauses it on purpose (n8n's Media space)
      {
        alert = "DownloadsPaused";
        expr = ''sabnzbd_queue_length > 0 and sabnzbd_paused == 1 unless on(host) axon_space_used_bytes{space="media"} / axon_space_limit_bytes{space="media"} > 0.9'';
        for = "2h";
        annotations.summary = "{{ $value }} queued, paused";
      }
      # the apps' own health checks; updates and upstream notices come with the system
      {
        alert = "ArrUnhealthy";
        expr = ''{__name__=~"(sonarr|radarr|prowlarr)_system_health_issues",type=~"warning|error",source!~"UpdateCheck|ServerSideNotificationService"} == 1'';
        for = "1h";
        annotations.summary = "{{ $labels.job }}: {{ $labels.message }}";
      }
    ];
  };
}
