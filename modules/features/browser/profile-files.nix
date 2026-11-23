# Profile files Zen rewrites itself, kept as dotfiles in .config/zen/<profile>/declared/ and applied
# while Zen is closed: at activation, before the session starts, and once Zen closes after a change.
{ lib, ... }:
{
  flake.modules.homeManager.browser =
    {
      config,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (config.programs.zen-browser) profilesPath;
      watched = lib.concatMap (
        profile:
        lib.concatMap (home: [
          "${home}/.config/zen/${profile}/declared"
          "${home}/.config/zen/${profile}/declared/storage-sync"
        ]) osConfig.axon.dotfiles
      ) (lib.attrNames config.programs.zen-browser.profiles);

      filter =
        name:
        pkgs.writeText "zen-${name}.jq" (
          builtins.readFile ./_zen-common.jq + builtins.readFile ./_zen-${name}.jq
        );

      load = pkgs.writeShellApplication {
        name = "zen-declared";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.lsof
          pkgs.mozlz4a
          pkgs.openssl
          pkgs.sqlite
        ];
        runtimeEnv = {
          SESSIONS_JQ = filter "sessions";
          LIVE_FOLDERS_JQ = filter "live-folders";
          ROUTING_JQ = filter "space-routing";
        };
        text = builtins.readFile ./_zen-declared.sh;
      };
    in
    {
      # after the dotfiles, which a fresh install links in that same activation
      home.activation.zenDeclared = config.lib.dag.entryAfter [ "linkGeneration" "dotfiles" ] ''
        ${lib.getExe load} ${lib.escapeShellArg profilesPath} || true
      '';

      systemd.user.services.zen-declared = {
        Unit = {
          Description = "Copy Zen's declared profile files in";
          Before = [ "graphical-session-pre.target" ];
        };
        Install.WantedBy = [ "graphical-session-pre.target" ];
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe load} ${lib.escapeShellArg profilesPath}";
        };
      };

      # an edit applies once Zen is closed; a later edit while this waits is read too
      systemd.user.paths.zen-declared-changed = {
        Unit.Description = "Watch Zen's declared profile files";
        Install.WantedBy = [ "default.target" ];
        Path.PathChanged = watched;
      };
      systemd.user.services.zen-declared-changed = {
        Unit.Description = "Copy Zen's changed profile files in once it is closed";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe load} ${lib.escapeShellArg profilesPath} wait";
        };
      };
    };
}
