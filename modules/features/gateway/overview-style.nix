# The start page's look: near-black, monospace, centered, flat cards with a thin border.
{
  flake.modules.nixos.gateway = {
    services.homepage-dashboard.customCSS = ''
      @import url("https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500&display=swap");

      :root {
        --bg: #0a0c0b;
        --card: #0f1211;
        --card-hover: #131715;
        --line: rgba(255, 255, 255, 0.06);
        --text: #e4e7e5;
        --muted: #6f7772;
        --accent: rgba(74, 222, 128, 0.35);
      }

      html,
      body,
      #page_wrapper {
        background: var(--bg) !important;
      }

      * {
        font-family: "JetBrains Mono", ui-monospace, monospace;
      }

      #services {
        max-width: 72rem;
        margin: 3rem auto 0 !important;
      }

      /* the refresh button; the page refreshes its numbers by itself */
      #footer {
        display: none;
      }

      .service-group-name {
        color: var(--muted) !important;
        font-size: 0.7rem !important;
        font-weight: 400 !important;
        letter-spacing: 0.18em;
        text-transform: uppercase;
      }

      .service-card {
        background: var(--card) !important;
        border: 1px solid var(--line);
        border-radius: 10px !important;
        padding: 0.25rem 0.375rem !important;
      }

      .service-card:hover {
        background: var(--card-hover) !important;
        border-color: var(--accent);
      }

      .service-name {
        color: var(--text);
        font-size: 0.8rem;
        font-weight: 400;
      }

      .service-description {
        color: var(--muted) !important;
        font-size: 0.7rem;
      }

      .service-block {
        background: transparent !important;
        padding: 0.125rem !important;
      }

      .service-block-value {
        color: var(--text);
        font-size: 0.85rem;
        font-weight: 300;
      }

      .service-block-label {
        color: var(--muted);
        font-size: 0.55rem;
        font-weight: 400;
        letter-spacing: 0.08em;
      }
    '';
  };
}
