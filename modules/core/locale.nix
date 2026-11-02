{ lib, ... }:
{
  flake.modules.nixos.core =
    { config, ... }:
    let
      inherit (config.axon) locale;
    in
    {
      time.timeZone = locale.timezone;

      i18n.defaultLocale = locale.language;
      i18n.extraLocaleSettings = lib.genAttrs [
        "LC_ADDRESS"
        "LC_MEASUREMENT"
        "LC_MONETARY"
        "LC_NAME"
        "LC_NUMERIC"
        "LC_PAPER"
        "LC_TELEPHONE"
        "LC_TIME"
      ] (_: locale.formats);

      services.xserver.xkb = {
        layout = locale.keyboard;
        inherit (locale) variant;
      };
      console.useXkbConfig = true;
    };
}
