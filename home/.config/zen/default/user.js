// Profile prefs, read by Zen on every start. Prefs changed in about:config are reset to these.

// ── browser ────────
// chrome/userChrome.css
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
// bookmarks.html next to this file, imported on every start
user_pref("browser.places.importBookmarksHTML", true);
user_pref("devtools.chrome.enabled", true);
user_pref("font.name.sans-serif.x-western", "Inter");
user_pref("font.name.serif.x-western", "Barlow");
user_pref("font.name.monospace.x-western", "JetBrainsMono Nerd Font");
user_pref("font.size.monospace.x-western", 13);

user_pref("browser.display.document_color_use", 0);
user_pref("browser.urlbar.clipboard.featureGate", false);
user_pref("browser.urlbar.suggest.addons", false);
user_pref("browser.urlbar.suggest.engines", false);
user_pref("browser.urlbar.suggest.mdn", false);
user_pref("browser.urlbar.suggest.topsites", false);
user_pref("browser.urlbar.suggest.trending", false);
user_pref("browser.urlbar.suggest.weather", false);
user_pref("browser.urlbar.suggest.yelp", false);

user_pref("general.smoothScroll", false);
user_pref("general.autoScroll", true);

// ── zen ────────
user_pref("zen.pinned-tab-manager.restore-pinned-tabs-to-pinned-url", true);
user_pref("zen.tabs.ctrl-tab.ignore-pending-tabs", true);
user_pref("zen.tabs.select-recently-used-on-close", false);
user_pref("zen.ui.migration.compact-mode-button-added", true);
user_pref("zen.view.compact.enable-at-startup", false);
user_pref("zen.view.show-newtab-button-top", false);
user_pref("zen.view.use-single-toolbar", false);
user_pref("zen.view.window.scheme", 0);
user_pref("zen.welcome-screen.seen", true);
user_pref("zen.workspaces.indicator-name-center", true);
user_pref("zen.workspaces.show-workspace-indicator", true);

// ── mod: Trackpad Animation ────────
user_pref("user-browser-scale", "0.99");
user_pref("user-browser-ease-swipe", "0.1, 0.5, 0.3, 0.1");
user_pref("user-browser-ease-reset", "0.1, 0.5, 0.3, 0.1");
user_pref("user-tab-radius", "8px");
user_pref("user-tab-movement", "0.5%");
user_pref("tab-shadow-enabled", true);
user_pref("border-shadow-disabled", true);

// ── mod: Better Find Bar ────────
user_pref("theme-better_find_bar-enable_custom_background", true);
user_pref("theme.better_find_bar.custom_background", "#1f1f1f");
user_pref("theme.better_find_bar.transparent_background", true);
user_pref("theme.better_find_bar.horizontal_position", "default");
user_pref("theme.better_find_bar.vertical_position", "default");
user_pref("theme.better_find_bar.textbox_width", "1000");
user_pref("theme.better_find_bar.hide_highlight", "not_hide");
user_pref("theme.better_find_bar.hide_match_case", "not_hide");
user_pref("theme.better_find_bar.hide_match_diacritics", "not_hide");
user_pref("theme.better_find_bar.hide_whole_words", "not_hide");
user_pref("theme.better_find_bar.instant_animations", false);
user_pref("theme.better_find_bar.hide_find_status", false);
user_pref("theme.better_find_bar.hide_found_matches", false);

// ── mod: SuperPins ────────
user_pref("uc.essentials.width", "");
user_pref("uc.essentials.gap", "");
user_pref("uc.pins.essentials-layout", false);
user_pref("uc.essentials.color-scheme", "");
user_pref("uc.essentials.box-like-corners", false);
user_pref("uc.essentials.same-height", true);
user_pref("uc.essentials.auto-grow", true);
user_pref("uc.essentials.transition-bg", false);
user_pref("uc.essentials.transition-speed", "100ms");
user_pref("uc.essentials.position", "");
user_pref("uc.superpins.border", "");
user_pref("uc.pins.legacy-layout", false);
user_pref("uc.pins.auto-grow", false);
user_pref("uc.pins.bg", false);
user_pref("uc.pins.transition-bg", false);
user_pref("uc.pins.transition-speed", "100ms");
user_pref("zen.workspaces.indicator-position", "");
user_pref("uc.pins.stay-at-top", true);
user_pref("uc.pins.active-bg", false);
user_pref("mod.superpins.pins.active-bg", "#ffffff");
user_pref("uc.tabs.strikethrough-on-pending", false);
user_pref("uc.remove-sidebar-scrollbar", true);
user_pref("uc.pins.separator-at-bottom", false);
user_pref("uc.tabs.show-separator", "pinned-shown");
user_pref("uc.tabs.dim-type", "both");
user_pref("uc.pinned.height", "small");
user_pref("uc.favicon.size", "normal");
user_pref("uc.workspace.icon.size", "");
user_pref("uc.workspace.current.icon.size", "");
user_pref("uc.essentials.grid-count", true);
user_pref("mod.superpins.essentials.grid-count", "3");
user_pref("uc.pins.grid-count", false);
user_pref("mod.superpins.pins.grid-count", "1");
