# The account mail leaves through: an SMTP relay ([smtp] in host.toml), reached with STARTTLS, as
# a home connection can't deliver mail itself. One login (secrets.json mail/login, mail/token)
# sends for every service, each from its own address on the cluster domain, so the relay must
# accept any sender on that domain. Alerts, failed units among them, are mailed by Alertmanager on
# the host running monitoring to srv-alert@ the cluster domain, filed away by a Sieve rule on the
# local part.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  axon.schema.mail = {
    options.smtp = {
      host = mkOption {
        type = types.str;
        example = "smtp.example.com";
        description = "SMTP relay, reached with STARTTLS; its login goes in secrets.json at mail/login and mail/token.";
      };
      port = mkOption {
        type = types.port;
        example = 587;
        description = "SMTP relay port.";
      };
    };
  };

  flake.modules.nixos.mail =
    { config, ... }:
    let
      inherit (config.axon)
        cluster
        host
        smtp
        ;
      ph = config.sops.placeholder;
      monitors = lib.filterAttrs (_: data: lib.elem "monitoring" data.host.features) cluster.hosts;
    in
    {
      axon.mail = {
        inherit (smtp) host port;
        login = ph."mail/login";
        token = ph."mail/token";
      };

      sops.secrets = {
        "mail/login" = { };
        "mail/token" = { };
      };

      warnings = lib.optional (
        monitors == { }
      ) "hosts/${host.name}/host.toml: no host lists monitoring, so alerts aren't mailed";
    };
}
