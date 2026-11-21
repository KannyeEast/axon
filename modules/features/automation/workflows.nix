# n8n at automation.<domain>: workflows that tie the services together. Tailnet only, behind the
# gate and n8n's own login, whose owner account is made on the first visit. Callers on this host
# send webhooks to its internal address, past the gate. Workflows and credentials live in its
# database, encrypted with a key n8n makes itself in the same folder.
{
  flake.modules.nixos.automation =
    { config, ... }:
    let
      inherit (config.axon.services.automation) route;
      state = "/var/lib/private/n8n";
    in
    {
      services.n8n = {
        enable = true;
        environment = {
          N8N_LISTEN_ADDRESS = "127.0.0.1";
          N8N_WEBHOOK_URL = route.origin;
          # the gateway: client addresses come from X-Forwarded-For
          N8N_PROXY_HOPS = 1;
        };
      };

      axon.persist.state.directories = [
        {
          directory = state;
          mode = "0700";
        }
      ];

      axon.services.automation = {
        units = [ "n8n" ];
        route.port = 5678;
        dashboard = {
          name = "n8n";
          group = "Code";
          description = "Workflows";
          icon = "n8n.svg";
          monitor = "/healthz";
        };
        backup.paths = [ state ];
      };
    };
}
