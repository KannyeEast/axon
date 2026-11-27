# Bitwarden: the password manager in Zen where a server runs Vaultwarden; gnome-keyring is the secret store.
# Settings: none; its server is preset to vault.<domain>.
{ lib, ... }:
{
  flake.modules.nixos.passwords =
    { config, pkgs, ... }:
    let
      inherit (config.axon.cluster) domain;
      bitwarden = "{446900e4-71c2-419f-a6a7-df9c091e268b}";
      vault =
        lib.filterAttrs (_: data: data.host.class == "server") (config.axon.hostsWith "passwords") != { };
      float = pkgs.writeShellApplication {
        name = "bitwarden-float";
        runtimeInputs = [
          config.programs.niri.package
          pkgs.jq
        ];
        text = ''
          declare -A floated
          niri msg --json event-stream \
            | jq --unbuffered -r '.WindowOpenedOrChanged.window? // empty
                | select(.app_id == "zen-beta" and (.title | test("^Extension: \\(Bitwarden")) and (.is_floating | not))
                | .id' \
            | while read -r id; do
                # once per window, so one tiled by hand stays tiled
                [[ -n ''${floated[$id]:-} ]] && continue
                floated[$id]=1
                niri msg action move-window-to-floating --id "$id"
              done
        '';
      };
    in
    lib.mkIf (config.axon.host.class == "desktop" && vault) {
      # ── session ────────
      # Zen titles the extension's popouts only after they open, past niri's open-floating rules
      # (niri FAQ); nirius has no rules, so this floats them on the title change
      systemd.user.services.bitwarden-float = {
        description = "Floats Bitwarden's popouts";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = lib.getExe float;
          Restart = "on-failure";
        };
      };

      # ── system ────────
      # enabling gnome-keyring also starts gcr's SSH agent; desktops run none
      services.gnome.gcr-ssh-agent.enable = false;

      # ── contracts ────────
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
