{
  flake.modules.homeManager.desktop = {
    config = {
      programs.zen-browser.profiles.default = {
        mods = [
          "378ba8b9-cd36-45f5-88df-595df5288795" # Add new tab urlbar icon
          "570afd9d-96fa-48b5-bad3-0c106757cce9" # Super Sleek UI
          "8039de3b-72e1-41ea-83b3-5077cf0f98d1" # Trackpad Animation
          "a6335949-4465-4b71-926c-4a52d34bc9c0" # Better Find Bar
          "ad97bb70-0066-4e42-9b5f-173a5e42c6fc" # SuperPins
        ];

        settings = {
          # Trackpad Animation
          "user-browser-scale" = "0.99";
          "user-browser-ease-swipe" = "0.1, 0.5, 0.3, 0.1";
          "user-browser-ease-reset" = "0.1, 0.5, 0.3, 0.1";
          "user-tab-radius" = "8px";
          "user-tab-movement" = "0.5%";
          "tab-shadow-enabled" = true;
          "border-shadow-disabled" = true;

          # Better Find Bar
          "theme-better_find_bar-enable_custom_background" = true;
          "theme.better_find_bar.custom_background" = "#1f1f1f";
          "theme.better_find_bar.transparent_background" = true;
          "theme.better_find_bar.horizontal_position" = "default";
          "theme.better_find_bar.vertical_position" = "default";
          "theme.better_find_bar.textbox_width" = "1000";
          "theme.better_find_bar.hide_highlight" = "not_hide";
          "theme.better_find_bar.hide_match_case" = "not_hide";
          "theme.better_find_bar.hide_match_diacritics" = "not_hide";
          "theme.better_find_bar.hide_whole_words" = "not_hide";
          "theme.better_find_bar.instant_animations" = false;
          "theme.better_find_bar.hide_find_status" = false;
          "theme.better_find_bar.hide_found_matches" = false;

          # SuperPins
          "uc.essentials.width" = "";
          "uc.essentials.gap" = "";
          "uc.pins.essentials-layout" = false;
          "uc.essentials.color-scheme" = "";
          "uc.essentials.box-like-corners" = false;
          "uc.essentials.same-height" = true;
          "uc.essentials.auto-grow" = true;
          "uc.essentials.transition-bg" = false;
          "uc.essentials.transition-speed" = "100ms";
          "uc.essentials.position" = "";
          "uc.superpins.border" = "";
          "uc.pins.legacy-layout" = false;
          "uc.pins.auto-grow" = false;
          "uc.pins.bg" = false;
          "uc.pins.transition-bg" = false;
          "uc.pins.transition-speed" = "100ms";
          "zen.workspaces.show-workspace-indicator" = true;
          "zen.workspaces.indicator-name-center" = true;
          "zen.workspaces.indicator-position" = "";
          "browser.sessionstore.restore_pinned_tabs_on_demand" = true;
          "uc.pins.stay-at-top" = true;
          "uc.pins.active-bg" = false;
          "mod.superpins.pins.active-bg" = "#ffffff";
          "uc.tabs.strikethrough-on-pending" = false;
          "uc.remove-sidebar-scrollbar" = true;
          "uc.pins.separator-at-bottom" = false;
          "uc.tabs.show-separator" = "pinned-shown";
          "uc.tabs.dim-type" = "both";
          "uc.pinned.height" = "small";
          "uc.favicon.size" = "normal";
          "uc.workspace.icon.size" = "";
          "uc.workspace.current.icon.size" = "";
          "uc.essentials.grid-count" = true;
          "mod.superpins.essentials.grid-count" = "3";
          "uc.pins.grid-count" = false;
          "mod.superpins.pins.grid-count" = "1";
        };
      };
    };
  };
}
