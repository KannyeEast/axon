# Extensions that read browser.storage.managed, so their settings can be declared as policy.
{ lib, ... }:
{
  flake.modules.homeManager.browser = {
    programs.zen-browser.policies = {
      "3rdparty".Extensions = {
        "uBlock0@raymondhill.net".adminSettings = lib.toJSON {
          userSettings = {
            uiTheme = "dark";
          };

          selectedFilterLists = [
            "user-filters"
            "ublock-filters"
            "ublock-badware"
            "ublock-privacy"
            "ublock-quick-fixes"
            "ublock-unbreak"
            "easylist"
            "easyprivacy"
            "urlhaus-1"
            "plowe-0"
            "fanboy-social"
            "fanboy-ai-suggestions"
            "easylist-chat"
            "easylist-newsletters"
            "easylist-notifications"
            "easylist-annoyances"
            "DEU-0"
          ];

          userFilters = ''
            accounts.google.com/gsi/*

            ! YouTube
            www.youtube.com###voice-search-button
            www.youtube.com##ytd-notification-topbar-button-renderer.ytd-masthead.style-scope
            www.youtube.com##ytd-button-renderer.ytd-masthead.style-scope
            youtube.com##ytd-guide-section-renderer:has([href="/feed/subscriptions"]) #items>:not(:first-child)
            youtube.com##ytd-rich-section-renderer:has-text(Most relevant)
            youtube.com##ytd-reel-shelf-renderer:has-text(Most relevant)
            www.youtube.com##ytd-guide-section-renderer.ytd-guide-renderer.style-scope:nth-of-type(6)
            www.youtube.com###section-items > ytd-guide-entry-renderer.ytd-guide-collapsible-section-entry-renderer.style-scope > .ytd-guide-entry-renderer.style-scope.yt-simple-endpoint
            www.youtube.com###section-items
            www.youtube.com###copyright
            www.youtube.com###guide-links-secondary
            www.youtube.com###guide-links-primary
            youtube.com##span[id*="country-code"]
            www.youtube.com##.yt-core-attributed-string--inline-block-mod
            www.youtube.com##.yt-badge-shape__icon
            www.youtube.com##.ytdChipsShelfWithVideoShelfRendererHost > div
            www.youtube.com###top-level-buttons-computed

            ! Reddit
            www.reddit.com##faceplate-expandable-section-helper
            www.reddit.com##faceplate-tracker[noun*="explore"]
            www.reddit.com##faceplate-tracker[noun*="all"]
            www.reddit.com##li.left-nav-create-community-button[slot="sr-creation-entrypoint-experiment"]
            www.reddit.com##hr.my-sm
            www.reddit.com##.mb-md.mx-md.flex.justify-self-end.legal-links
            www.reddit.com##.mb-md.mx-md.flex.\!mx-0.legal-links
            reddit.com##reddit-search-large[show-ask-button]:remove-attr(show-ask-button)
            ||www.redditstatic.com/shreddit/search-input-desktop-client-css$css,domain=reddit.com
            www.reddit.com##reddit-search-large[show-snoo-leading-icon]:remove-attr(show-snoo-leading-icon)
            www.reddit.com##div.h-\[40px\].flex:nth-of-type(1)
            www.reddit.com##recent-posts
            www.reddit.com###left-sidebar-container > faceplate-tracker
            www.reddit.com###right-sidebar-container
          '';
        };
      };
    };
  };
}
