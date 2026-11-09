# Browser policies (about:policies); profile prefs are in the dotfiles (user.js).
{ lib, ... }:
let
  inherit (lib) optionals;
in
{
  flake.modules.homeManager.browser =
    { osConfig, ... }:
    let
      inherit (osConfig.axon) overlay;
      inherit (osConfig.axon.cluster) domain;
    in
    {
      # about:policies#documentation
      programs.zen-browser.policies = {
        AIControls.Default.Value = "blocked";
        AutofillAddressEnabled = false;
        AutofillCreditCardEnabled = false;
        BrowserDataBackup = {
          AllowBackup = false;
          AllowRestore = false;
        };
        Cookies = {
          Allow = [
            "file:///"
            "https://addy.io"
            "https://proton.me"
            "https://kagi.com"
            "https://github.com"
            "https://gitlab.com"
            "https://codeberg.org"
            "https://cloudflare.com"
            "https://tailscale.com"
          ]
          ++ optionals (domain != null) [
            "https://${domain}"
          ];
          Behavior = "reject-tracker-and-partition-foreign";
          BehaviorPrivateBrowsing = "reject-tracker-and-partition-foreign";
        };
        DisableAppUpdate = true;
        DisableFeedbackCommands = true;
        DisableFirefoxStudies = true;
        DisableSetDesktopBackground = true;
        DisableTelemetry = true;
        # on the tailnet lookups use its DNS, which the gateway filters
        DNSOverHTTPS = {
          Enabled = overlay.network == null;
          ProviderURL = "https://mozilla.cloudflare-dns.com/dns-query";
          Fallback = true;
        };
        DontCheckDefaultBrowser = true;
        EnableTrackingProtection = {
          Category = "strict";
          BaselineExceptions = true;
        };
        FirefoxSuggest = {
          WebSuggestions = false;
          SponsoredSuggestions = false;
          ImproveSuggest = false;
        };
        GenerativeAI.Enable = false;
        Homepage = {
          URL = "https://kagi.com";
          Additional = [ "about:blank" ];
          StartPage = "previous-session";
        };
        InstallAddonsPermission.Default = false;
        NetworkPrediction = false;
        NewTabPage = false;
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        Permissions = {
          Location.BlockNewRequests = true;
          Notifications.BlockNewRequests = true;
          Autoplay.BlockNewRequests = true;
          VirtualReality.BlockNewRequests = true;
          ScreenShare.BlockNewRequests = true;
        };
        PictureInPicture.Enabled = false;
        PromptForDownloadLocation = true;
        SanitizeOnShutdown = {
          Cache = true;
          Cookies = true;
          FormData = true;
          History = true;
          Sessions = false;
          SiteSettings = false;
        };
        SearchSuggestEnabled = false;
        ShowHomeButton = true;
        SkipTermsOfUse = true;
        StartDownloadsInTempDirectory = true;
        TranslateEnabled = false;
        VisualSearchEnabled = false;
        UserMessaging = {
          WhatsNew = false;
          ExtensionRecommendations = false;
          FeatureRecommendations = false;
          UrlbarInterventions = false;
          SkipOnboarding = true;
          MoreFromMozilla = false;
          FirefoxLabs = false;
        };
      };
    };
}
