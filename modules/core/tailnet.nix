{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) host secrets;
    in
    {
      # every machine joins the private network; cluster relations (ssh, sync, the gateway) run over it
      assertions = [
        {
          assertion = secrets ? tailscale-authkey;
          message = "hosts/${host.name}/secrets.json: every host needs a 'tailscale-authkey'";
        }
      ];

      sops.secrets.tailscale-authkey = { };

      services.tailscale = {
        enable = true;
        openFirewall = true;
        authKeyFile = config.sops.secrets.tailscale-authkey.path;
      };
      services.resolved.enable = true; # MagicDNS

      axon.persist.directories = [
        {
          directory = "/var/lib/tailscale";
          mode = "0700";
        }
      ];
    };
}
