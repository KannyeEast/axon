# Mail leaves through Proton's SMTP with a token; a home connection can't deliver mail itself.
# Swapping the provider means changing axon.mail's host and port here, and the secrets.
# The sender address lives in secrets.json (mail/user, mail/domain, mail/token), so it never
# lands in the repo. Recipients are srv-alert@, srv-report@ and srv-info@ the cluster domain,
# which a Sieve rule on the recipient's local part files away. Failure mails and the weekly report
# come from _notify/notify.py; every mail of ours uses the page in _notify/page.html.
{ lib, ... }:
{
  flake.modules.nixos.mail =
    { config, pkgs, ... }:
    let
      inherit (config.axon) domain mail;
      ph = config.sops.placeholder;
      levels = {
        ok = {
          color = "#1b7f5c";
          tint = "#e6f5ef";
        };
        warn = {
          color = "#a8660a";
          tint = "#fdf3e1";
        };
        fail = {
          color = "#c8233f";
          tint = "#fde8ec";
        };
      };
      settings = pkgs.writeText "notify.json" (
        lib.toJSON {
          inherit levels;
          page = "${./_notify/page.html}";
          sendmail = "/run/wrappers/bin/sendmail";
        }
      );
      notify = "${lib.getExe' pkgs.python3 "python3"} ${./_notify/notify.py} ${settings}";
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
        report = "srv-report@${domain}";
        info = "srv-info@${domain}";
        page = lib.readFile ./_notify/page.html;
        inherit levels;
      };

      sops.secrets = {
        "mail/user" = { };
        "mail/domain" = { };
        "mail/token" = { };
      };

      sops.templates.msmtprc = {
        mode = "0444"; # sendmail runs as whichever service fails; the token is send-only
        content = ''
          defaults
          auth on
          tls on
          logfile -

          account proton
          host ${mail.host}
          port ${toString mail.port}
          from ${mail.address}
          user ${mail.address}
          password ${mail.token}

          account default : proton
        '';
      };

      programs.msmtp.enable = true;
      # the rendered config with the secrets in it replaces the one Nix would write
      environment.etc."msmtprc" = lib.mkForce { source = config.sops.templates.msmtprc.path; };

      # every failing service mails srv-alert@, except the mailer itself: a drop-in of the same name
      # linked to /dev/null masks the first one, as an empty OnFailure= can't clear a dependency
      systemd.packages = [
        (pkgs.writeTextDir "lib/systemd/system/service.d/90-axon-alert.conf" ''
          [Unit]
          OnFailure=alert@%n.service
        '')
        (pkgs.runCommand "axon-no-alert" { } ''
          mkdir -p $out/lib/systemd/system/alert@.service.d
          ln -s /dev/null $out/lib/systemd/system/alert@.service.d/90-axon-alert.conf
        '')
      ];

      systemd.services."alert@" = {
        description = "Mail a failed unit to ${mail.alert}";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${notify} alert ${mail.alert} %i";
        };
        path = [ pkgs.systemd ];
      };

      services.smartd.notifications = {
        wall.enable = false;
        mail = {
          enable = true;
          recipient = mail.alert;
          sender = mail.alert;
        };
      };

      # a short health summary every Sunday evening
      systemd.services.report = {
        description = "Weekly report to ${mail.report}";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${notify} report ${mail.report}";
        };
        path = [
          pkgs.btrfs-progs
          pkgs.coreutils
          pkgs.smartmontools
          pkgs.systemd
          pkgs.util-linux
        ];
      };
      systemd.timers.report = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Sun 18:00";
          Persistent = true;
        };
      };
    };
}
