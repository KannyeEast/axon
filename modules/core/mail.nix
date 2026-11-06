# Contract: axon.mail. The account outgoing mail leaves through, set by the mail feature.
# Null on a host without it: a consumer then sends nothing and says so if that matters.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  secret =
    description:
    mkOption {
      type = types.str;
      description = "${description} A sops placeholder: only valid inside a sops template.";
    };
in
{
  flake.modules.nixos.core = {
    options.axon.mail = mkOption {
      default = null;
      description = "The outgoing mail account. Consumers must work with null.";
      type = types.nullOr (
        types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              description = "SMTP server, reached with STARTTLS.";
            };
            port = mkOption {
              type = types.port;
              description = "SMTP port.";
            };
            user = secret "Local part of the sender address.";
            domain = secret "Domain of the sender address.";
            address = secret "Sender address, also the SMTP login.";
            token = secret "SMTP password.";
            alert = mkOption {
              type = types.str;
              description = "Recipient for failures.";
            };
            report = mkOption {
              type = types.str;
              description = "Recipient for scheduled reports.";
            };
            info = mkOption {
              type = types.str;
              description = "Recipient for notices: worth reading, but nothing is wrong.";
            };
          };
        }
      );
    };
  };
}
