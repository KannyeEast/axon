# Browser policies (about:policies), and the profile settings they don't cover.
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
      mkPolicy = lib.mapAttrs (_: Value: { inherit Value; });
    in
    {
      # about:policies#documentation
      programs.zen-browser.policies = {
        AIControls.Default.Value = "blocked";
        AppAutoUpdate = false;
        AutofillAddressEnabled = false;
        AutofillCreditCardEnabled = false;
        BackgroundAppUpdate = false;
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
        FirefoxHome = {
          Search = true;
          Weather = false;
          TopSites = false;
          SponsoredTopSites = false;
          Highlights = false;
          Pocket = false;
          Stories = false;
          SponsoredPocket = false;
          SponsoredStories = false;
          Snippets = false;
        };
        FirefoxSuggest = {
          WebSuggestions = false;
          SponsoredSuggestions = false;
          ImproveSuggest = false;
        };
        GenerativeAI.Enable = false;
        HardwareAcceleration = true;
        Homepage = {
          URL = "https://kagi.com";
          Additional = [ "about:blank" ];
          StartPage = "previous-session";
        };
        HttpsOnlyMode = "allowed";
        InstallAddonsPermission.Default = false;
        NetworkPrediction = false;
        NewTabPage = false;
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        Permissions = {
          Camera = {
            Allow = [ ];
            Block = [ ];
            BlockNewRequests = false;
          };
          Microphone = {
            Allow = [ ];
            Block = [ ];
            BlockNewRequests = false;
          };
          Location = {
            Allow = [ ];
            Block = [ ];
            BlockNewRequests = true;
          };
          Notifications = {
            Allow = [ ];
            Block = [ ];
            BlockNewRequests = true;
          };
          Autoplay = {
            Allow = [ ];
            Block = [ ];
            BlockNewRequests = true;
          };
          VirtualReality = {
            Allow = [ ];
            Block = [ ];
            BlockNewRequests = true;
          };
          ScreenShare = {
            Allow = [ ];
            Block = [ ];
            BlockNewRequests = true;
          };
        };
        PictureInPicture.Enabled = false;
        PopupBlocking.Default = true;
        PrintingEnabled = true;
        PromptForDownloadLocation = true;
        SanitizeOnShutdown = {
          Cache = true;
          Cookies = true;
          FormData = true;
          History = true;
          Sessions = false;
          SiteSettings = false;
        };
        SearchBar = "unified";
        SearchSuggestEnabled = false;
        ShowHomeButton = true;
        SkipTermsOfUse = true;
        StartDownloadsInTempDirectory = true;
        TranslateEnabled = false;
        VisualSearchEnabled = false;
        Preferences = mkPolicy {
          "browser.display.document_color_use" = 0;
          "browser.tabs.warnOnClose" = false;
          "browser.urlbar.clipboard.featureGate" = false;
          "browser.urlbar.addons.featureGate" = false;
          "browser.urlbar.suggest.addons" = false;
          "browser.urlbar.suggest.engines" = false;
          "browser.urlbar.suggest.mdn" = false;
          # the row of sites Zen's new tab launcher opens with
          "browser.urlbar.suggest.topsites" = false;
          "browser.urlbar.suggest.trending" = false;
          "browser.urlbar.suggest.weather" = false;
          "browser.urlbar.suggest.yelp" = false;
          "browser.urlbar.trending.featureGate" = false;
          "browser.urlbar.quicksuggest.enabled" = false;

          "general.smoothScroll" = false;
          # middle-click scrolling; Firefox leaves it off on Linux, where middle click pastes
          "general.autoScroll" = true;
        };
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

      programs.zen-browser.profiles.default.settings = {
        "devtools.chrome.enabled" = true;

        "font.default.x-western" = "serif";
        "font.name.sans-serif.x-western" = "Inter";
        "font.name.serif.x-western" = "Barlow";
        "font.name.monospace.x-western" = "JetBrainsMono Nerd Font";
        "font.size.variable.x-western" = 16;
        "font.size.monospace.x-western" = 13;

        "zen.pinned-tab-manager.restore-pinned-tabs-to-pinned-url" = true;
        "zen.tabs.ctrl-tab.ignore-pending-tabs" = true;
        "zen.tabs.select-recently-used-on-close" = false;
        "zen.ui.migration.compact-mode-button-added" = true;
        "zen.view.compact.enable-at-startup" = false;
        "zen.view.show-newtab-button-top" = false;
        "zen.view.use-single-toolbar" = false;
        "zen.view.window.scheme" = 0;
        "zen.welcome-screen.seen" = true;
        "zen.workspaces.indicator-name-center" = true;
        "zen.workspaces.show-workspace-indicator" = true;
      };
    };
}
