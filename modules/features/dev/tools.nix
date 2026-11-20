# IT Tools at tools.<domain> on servers: converters, encoders and generators in the browser, so
# nothing is pasted into a website. A static page, tailnet only, behind the gateway's login.
{ lib, ... }:
{
  flake.modules.nixos.dev =
    { config, pkgs, ... }:
    let
      port = 8787;
    in
    lib.mkIf (config.axon.host.class == "server") {
      services.static-web-server = {
        enable = true;
        listen = "127.0.0.1:${toString port}";
        root = "${pkgs.it-tools}/lib";
        # its pages are routes of one app, so a link to one is answered with the app
        configuration.general.page-fallback = "${pkgs.it-tools}/lib/index.html";
      };

      axon.services.tools = {
        units = [ "static-web-server" ];
        route.port = port;
        dashboard = {
          name = "IT Tools";
          group = "Code";
          description = "Developer utilities";
          icon = "it-tools.svg";
        };
      };
    };
}
