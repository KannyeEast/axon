# Contract: axon.mail. The account outgoing mail leaves through and the domain it is sent from,
# set by the mail feature. Null on a host without it: a consumer then sends nothing and says so if
# that matters.
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
            login = secret "SMTP login.";
            token = secret "SMTP password.";
            domain = mkOption {
              type = types.str;
              description = "Domain of the senders: a service sends as <its axon.services name>@domain, all with the one login.";
            };
            alert = mkOption {
              type = types.str;
              description = "Recipient for alerts.";
            };
            page = mkOption {
              type = types.str;
              description = "The HTML around a mail's content, for the sender to fill in: @preview@ (the inbox's preview line), @label@, @color@, @tint@, @bar@, @title@, @subtitle@, @body@ and @footer@. Sections in @body@ follow the page's style: a rule above, a small uppercase heading.";
            };
            levels = mkOption {
              type = types.attrsOf (types.attrsOf types.str);
              description = "Colours per level (ok, info, fail): the label's color and tint, and the bar across the top.";
            };
          };
        }
      );
    };
  };
}
