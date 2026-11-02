# Mail leaves through Proton's SMTP with a token; a home connection can't deliver mail itself.
# The sender address lives in secrets.json (mail/user, mail/domain, mail/token), so it never
# lands in the repo. Recipients are srv-alert@ and srv-report@ the cluster domain, which a
# Sieve rule on the recipient's local part files away.
{ lib, ... }:
{
  flake.modules.nixos.server =
    { config, pkgs, ... }:
    let
      inherit (config.axon) host cluster;
      ph = config.sops.placeholder;
      domain =
        if cluster.domain != null then
          cluster.domain
        else
          throw "cluster.toml: a server needs a domain for its mail";
      sendmail = "/run/wrappers/bin/sendmail";
    in
    {
      options.axon.mail = {
        alert = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "srv-alert@${domain}";
          description = "Recipient for failures.";
        };
        report = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "srv-report@${domain}";
          description = "Recipient for scheduled reports.";
        };
      };

      config = {
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
            tls_starttls on
            tls_trust_file /etc/ssl/certs/ca-certificates.crt
            logfile -

            account proton
            host smtp.protonmail.ch
            port 587
            from ${ph."mail/user"}@${ph."mail/domain"}
            user ${ph."mail/user"}@${ph."mail/domain"}
            password ${ph."mail/token"}

            account default : proton
          '';
        };

        programs.msmtp = {
          enable = true;
          setSendmail = true;
        };
        # the rendered config with the secrets in it replaces the one Nix would write
        environment.etc."msmtprc" = lib.mkForce { source = config.sops.templates.msmtprc.path; };

        # every failing service mails srv-alert@, except the mailer itself
        systemd.packages = [
          (pkgs.writeTextDir "lib/systemd/system/service.d/90-axon-alert.conf" ''
            [Unit]
            OnFailure=alert@%n.service
          '')
          (pkgs.writeTextDir "lib/systemd/system/alert@.service.d/99-axon-no-loop.conf" ''
            [Unit]
            OnFailure=
          '')
        ];

        systemd.services."alert@" = {
          description = "Mail a failed unit to ${config.axon.mail.alert}";
          serviceConfig.Type = "oneshot";
          scriptArgs = "%i";
          path = [ pkgs.systemd ];
          script = ''
            # systemd triggers this before its own message about the failure reaches the journal
            sleep 2
            journalctl --sync
            {
              echo "To: ${config.axon.mail.alert}"
              echo "Subject: [${host.name}] $1 failed"
              echo
              # status only shows the log of the unit's current run; once it has restarted, the
              # failed run's lines are only in the journal
              report() {
                systemctl status --full --lines=0 "$1" || true
                echo
                journalctl --unit="$1" --boot --lines=40 --no-pager --no-hostname
              }
              report "$1"
              # a "dependency" failure has its error in the unit it depends on
              for dep in $(systemctl show --property=Requires,Requisite,BindsTo --value "$1"); do
                if systemctl --quiet is-failed "$dep"; then
                  echo
                  report "$dep"
                fi
              done
            } | ${sendmail} -t
          '';
        };

        services.smartd.notifications = {
          wall.enable = false;
          mail = {
            enable = true;
            recipient = config.axon.mail.alert;
            sender = config.axon.mail.alert;
          };
        };

        # a short health summary every Sunday evening
        systemd.services.report = {
          description = "Weekly report to ${config.axon.mail.report}";
          serviceConfig.Type = "oneshot";
          path = [
            pkgs.btrfs-progs
            pkgs.coreutils
            pkgs.gawk
            pkgs.smartmontools
            pkgs.systemd
            pkgs.util-linux
          ];
          script = ''
            {
              echo "To: ${config.axon.mail.report}"
              echo "Subject: [${host.name}] weekly report"
              echo
              echo "== system"
              echo "$(cat /run/current-system/nixos-version), up $(uptime -p | cut -d' ' -f2-)"
              echo "last switch: $(date -r /run/current-system '+%F %R')"
              echo
              echo "== failed units"
              systemctl --failed --no-legend --plain | awk '{print $1}' | sed 's/^/  /' || true
              echo
              echo "== space"
              df -h --output=target,size,used,avail,pcent -x tmpfs -x devtmpfs -x efivarfs | sed 's/^/  /'
              echo
              echo "== disks (SMART)"
              for disk in $(lsblk -dno PATH,TYPE | awk '$2 == "disk" {print $1}'); do
                echo "  $disk: $(smartctl -H "$disk" | awk -F': ' '/overall-health|SMART Health Status/ {print $2}')"
              done
              echo
              echo "== btrfs errors"
              for mount in $(findmnt -rn -t btrfs -o TARGET | sort -u); do
                errors=$(btrfs device stats "$mount" 2>/dev/null | awk '$2 != 0' | wc -l)
                echo "  $mount: $errors"
              done
            } | ${sendmail} -t
          '';
        };
        systemd.timers.report = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "Sun 18:00";
            Persistent = true;
          };
        };
      };
    };
}
