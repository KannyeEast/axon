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
      popouts = pkgs.writeShellApplication {
        name = "bitwarden-popouts";
        runtimeInputs = [
          config.programs.niri.package
          pkgs.jq
        ];
        text = ''
          declare -A settled
          niri msg --json event-stream \
            | jq --unbuffered -r '
                (.WindowsChanged.windows[]? | ["known", .id] | @tsv),
                (.WindowOpenedOrChanged.window? // empty | select(.app_id == "zen-beta")
                  | ["zen", .id, .is_floating, .title] | @tsv)' \
            | while IFS=$'\t' read -r kind id floating title; do
                # windows open before this ran, or settled once, are left as they are
                if [[ $kind == known ]]; then settled[$id]=1; continue; fi
                [[ -n ''${settled[$id]:-} ]] && continue
                if [[ $title == "Zen Browser" ]]; then
                  # untitled yet: only the first window, never a popout, is placed at once
                  zen=$(niri msg --json windows | jq '[.[] | select(.app_id == "zen-beta")] | length')
                  [[ $zen == 1 ]] || continue
                elif [[ $title =~ ^Extension:\ \(|^Picture-in-Picture$ ]]; then
                  [[ $floating == true ]] || niri msg action move-window-to-floating --id "$id"
                  settled[$id]=1
                  continue
                fi
                [[ $floating == true ]] && niri msg action move-window-to-tiling --id "$id"
                settled[$id]=1
              done
        '';
      };
    in
    lib.mkIf (config.axon.host.class == "desktop" && vault) {
      # ── session ────────
      # Zen titles its windows only after they open, past niri's open-floating rules (niri FAQ), and
      # nirius has no rules: windows.kdl floats every new one, this tiles the browser windows again
      systemd.user.services.bitwarden-popouts = {
        description = "Keeps Bitwarden's popouts floating";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = lib.getExe popouts;
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
