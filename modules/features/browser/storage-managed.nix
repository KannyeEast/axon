{
  # Extensions that read browser.storage.managed, so their settings can be declared as policy.
  flake.modules.homeManager.browser = {
    config = {
      programs.zen-browser.policies = {
        "3rdparty".Extensions = {
          "uBlock0@raymondhill.net".adminSettings = builtins.toJSON {
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

            whitelist = [
              "chrome-extension-scheme"
              "moz-extension-scheme"
            ];

            dynamicFilteringString = ''
              * vo.aicdn.com * noop
              * ajax.googleapis.com * noop
              * js.appboycdn.com * noop
              * ajax.aspnetcdn.com * noop
              * materialdesignicons.b-cdn.net * noop
              * libs.baidu.com * noop
              * lib.baomitu.com * noop
              * apps.bdimg.com * noop
              * cdn.bootcdn.net * noop
              * cdn.bootcss.com * noop
              * maxcdn.bootstrapcdn.com * noop
              * netdna.bootstrapcdn.com * noop
              * stackpath.bootstrapcdn.com * noop
              * ajax.cloudflare.com * noop
              * cdnjs.cloudflare.com * noop
              * use.fontawesome.com.cdn.cloudflare.net * noop
              * code.createjs.com * noop
              * cdn.datatables.net * noop
              * cdn.embed.ly * noop
              * use.fontawesome.com * noop
              * fonts.googleapis.com * noop
              * sdn.inbond.gslb.geekzu.org * noop
              * sdn.geekzu.org * noop
              * gitcdn.github.io * noop
              * gstaticadssl.l.google.com * noop
              * fonts.gstatic.com * noop
              * mat1.gtimg.com * noop
              * cds.s5x3j6q5.hwcdn.net * noop
              * apps.bdimg.jomodns.com * noop
              * code.jquery.com * noop
              * jsdelivr.map.fastly.net * noop
              * cdn.jsdelivr.net * noop
              * akamai-webcdn.kgstatic.net * noop
              * lib.sinaapp.com * noop
              * ajax.loli.net * noop
              * cdnjs.loli.net * noop
              * fonts.loli.net * noop
              * cdn.embed.ly.cdn.cloudflare.net * noop
              * cdn.bootcss.com.maoyundns.com * noop
              * cdn.bootcdn.net.maoyundns.com * noop
              * cdn.materialdesignicons.com * noop
              * cdn.mathjax.org * noop
              * ajax.microsoft.com * noop
              * mscomajax.vo.msecnd.net * noop
              * cdn.jsdelivr.net.cdn.cloudflare.net * noop
              * ajax.loli.net.cdn.cloudflare.net * noop
              * cdnjs.loli.net.cdn.cloudflare.net * noop
              * fonts.loli.net.cdn.cloudflare.net * noop
              * akamai-webcdn.kgstatic.net.edgesuite.net * noop
              * dualstack.osff.map.fastly.net * noop
              * pagecdn.io * noop
              * cdn.plyr.io * noop
              * lib.baomitu.com.qh-cdn.com * noop
              * iduwdjf.qiniudns.com * noop
              * mat1.gtimg.com.tegsea.tc.qq.com * noop
              * cdn.ravenjs.com * noop
              * mathjax.rstudio.com * noop
              * developer.n.shifen.com * noop
              * lb.sae.sina.com.cn * noop
              * cdn.staticfile.org * noop
              * unpkg.com * noop
              * upcdn.b0.upaiyun.com * noop
              * gateway.cname.ustclug.org * noop
              * ajax.proxy.ustclug.org * noop
              * yandex.st * noop
              * yastatic.net * noop
              * vjs.zencdn.net * noop
              behind-the-scene * * noop
              behind-the-scene * 1p-script noop
              behind-the-scene * 3p noop
              behind-the-scene * 3p-frame noop
              behind-the-scene * 3p-script noop
              behind-the-scene * image noop
              behind-the-scene * inline-script noop
            '';

            hostnameSwitchesString = ''
              no-csp-reports: * true
              no-large-media: behind-the-scene false
            '';

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
  };
}
