# Bitwarden: the password manager in Zen where a server runs Vaultwarden; gnome-keyring is the secret store.
# Settings: none; its server is preset to vault.<domain>.
{ lib, ... }:
{
  flake.modules.nixos.passwords =
    { config, ... }:
    let
      inherit (config.axon.cluster) domain;
      bitwarden = "{446900e4-71c2-419f-a6a7-df9c091e268b}";
      vault =
        lib.filterAttrs (_: data: data.host.class == "server") (config.axon.hostsWith "passwords") != { };
    in
    lib.mkIf (config.axon.host.class == "desktop" && vault) {
      # enabling gnome-keyring also starts gcr's SSH agent; desktops run none
      services.gnome.gcr-ssh-agent.enable = false;

      axon.browser = {
        extensions.${bitwarden} = {
          id = "bitwarden-password-manager";
          pinned = true;
          private = true;
        };
        policies = {
          OfferToSaveLogins = false;
          PasswordManagerEnabled = false;
          # the extension reads its server from managed storage, which this policy fills
          "3rdparty" = lib.mkIf (domain != null) {
            Extensions.${bitwarden}.environment.base = "https://vault.${domain}";
          };
        };
      };
    };
}
