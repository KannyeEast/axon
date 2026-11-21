# The account mail leaves through: Proton's SMTP with a token, as a home connection can't deliver
# mail itself. The sender lives in secrets.json (mail/user, mail/domain, mail/token), out of the
# repo. Alerts, failed units among them, are mailed by Alertmanager on the host running monitoring
# to srv-alert@ the cluster domain, filed away by a Sieve rule on the local part, in the page in
# _page.html.
{ lib, ... }:
{
  flake.modules.nixos.mail =
    { config, ... }:
    let
      inherit (config.axon)
        cluster
        domain
        host
        mail
        ;
      ph = config.sops.placeholder;
      monitors = lib.filterAttrs (_: data: lib.elem "monitoring" data.host.features) cluster.hosts;
    in
    {
      axon.mail = {
        host = "smtp.protonmail.ch";
        port = 587;
        user = ph."mail/user";
        domain = ph."mail/domain";
        address = "${mail.user}@${mail.domain}";
        token = ph."mail/token";
        alert = "srv-alert@${domain}";
        page = lib.readFile ./_page.html;
        levels = {
          ok = {
            color = "#15803D";
            tint = "#DCFCE7";
            bar = "#16A34A";
          };
          fail = {
            color = "#B91C1C";
            tint = "#FEE2E2";
            bar = "#DC2626";
          };
        };
      };

      sops.secrets = {
        "mail/user" = { };
        "mail/domain" = { };
        "mail/token" = { };
      };

      warnings = lib.optional (
        monitors == { }
      ) "hosts/${host.name}/host.toml: no host lists monitoring, so alerts aren't mailed";
    };
}
