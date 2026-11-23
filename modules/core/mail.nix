# Contract: axon.mail. The account outgoing mail leaves through, set by the mail feature; a
# service sends as <its axon.services name>@<cluster domain>, all with the one login. Null on a
# host without it: a consumer then sends nothing and says so if that matters.
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
      description = "The outgoing mail account; a service sends as <its axon.services name>@<cluster domain>. Consumers must work with null.";
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
          };
        }
      );
    };
  };
}
