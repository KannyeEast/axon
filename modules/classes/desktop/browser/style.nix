# Deliberately small: font, rounding, a calmer tab list, the folder redesign and a few
# hidden extras. Anything Zen already does well is left alone.
{
  flake.modules.homeManager.desktop = {
    programs.zen-browser.profiles.default.userChrome = ''
      * {
          font-family: 'Inter', sans-serif;
      }

      :root {
          --zen-border-radius: 8px !important;
      }

      /* translucent tab strip */
      .browserSidebarContainer {
          background-color: rgba(0, 0, 0, 0.226) !important;
      }

      .urlbar-background {
          border: 2px solid #ffffff13 !important;
      }

      /* selected tab: a soft fill instead of a shadow; unloaded tabs dimmed */
      .tab-background:is([selected], [multiselected]) {
          box-shadow: none !important;
          background-color: rgba(255, 255, 255, 0.17) !important;
      }
      .tabbrowser-tab[pending="true"] .tab-icon-stack {
          opacity: 0.5;
      }

      /* ── folders ──────── */
      zen-folder {
          --folder-rail-inset: calc(4px + var(--tab-inline-padding, 8px) + 6px);

          margin: 0 !important;
          padding: 0 !important;

          & .tab-group-folder-icon {
              opacity: 1 !important;
              background-color: currentColor !important;
              mask-image: url("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23000' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'><path d='M6 9l6 6 6-6'/></svg>");
              mask-size: 14px 14px;
              mask-repeat: no-repeat;
              mask-position: center;
              transition: rotate 0.2s ease !important;

              & > svg {
                  display: none !important;
              }
          }

          & .tab-group-label-container {
              &:after {
                  display: none !important;
              }
          }

          & .tab-group-label {
              background: transparent !important;
              border: unset !important;
              font-weight: 500 !important;
              text-align: unset !important;
              color: var(--sidebar-text-color) !important;
          }

          & .tab-group-container {
              position: relative !important;
              margin-inline-start: var(--folder-rail-inset) !important;
              padding-inline-start: 5px !important;
          }

          /* Rail runs first favicon centre to last, so it stops half
             a tab short at each end instead of spanning the box */
          & .tab-group-container::before {
              content: "";
              position: absolute;
              inset-block: calc(var(--tab-min-height, 36px) / 2);
              inset-inline-start: -1px;
              width: 2px;
              border-radius: 1px;
              background-color: color-mix(in srgb, currentColor 50%, transparent);
          }

          /* Collapse even when the active tab lives in this folder;
             Zen otherwise keeps the container laid out */
          &[collapsed] .tab-group-container {
              display: none !important;
          }

          & .tab-group-overflow-count {
              font-weight: 400 !important;
              opacity: 0.55;
          }

          &[collapsed] .tab-group-folder-icon {
              rotate: -90deg;
          }
      }

      /* Live folders are fetched, not owned: sync glyph, no rotation */
      zen-folder:has(.reset-icon[live-folder-action]) .tab-group-folder-icon {
          mask-image: url("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23000' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><path d='M20 11a8.1 8.1 0 0 0-15.5-2m-.5-4v4h4'/><path d='M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4'/></svg>") !important;
          rotate: none !important;
      }

      /* Per-tab unload buttons, but keep live-folder status icons */
      .reset-icon:not([live-folder-action]) {
          display: none !important;
      }

      /* clutter */
      #picture-in-picture-button,
      #identity-icon-label,
      .tab-icon-overlay,
      .zen-workspace-close-unpinned-tabs-button {
          display: none !important;
      }
    '';
  };
}
