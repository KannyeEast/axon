# The start page's look: near-black, monospace, flat cards with a thin border and one green accent.
{
  flake.modules.nixos.gateway = {
    services.homepage-dashboard.customCSS = ''
      @import url("https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600&display=swap");

      :root {
        --bg: #0a0c0b;
        --card: #111412;
        --card-hover: #151a17;
        --line: rgba(255, 255, 255, 0.07);
        --text: #e4e7e5;
        --muted: #7f8782;
        --accent: #4ade80;
      }

      html,
      body,
      #page_wrapper {
        background: var(--bg) !important;
      }

      * {
        font-family: "JetBrains Mono", ui-monospace, monospace;
      }

      /* the header: resources and clock in one framed bar */
      #information-widgets {
        margin: 1.5rem 2rem 0;
        padding: 0.75rem 1rem;
        border: 1px solid var(--line);
        border-radius: 12px;
        background: var(--card);
      }

      #information-widgets * {
        color: var(--muted);
        font-size: 0.75rem;
      }

      #tabs ul {
        background: transparent !important;
        justify-content: center;
        gap: 0.75rem;
      }

      #tabs li {
        max-width: 9rem;
      }

      #tabs button {
        border: 1px solid var(--line);
        background: var(--card);
        color: var(--muted);
      }

      #tabs button[aria-selected="true"] {
        color: var(--text);
        border-color: var(--accent);
        box-shadow: inset 0 -2px 0 var(--accent);
      }

      .service-group-name {
        color: var(--muted) !important;
        font-size: 0.75rem !important;
        letter-spacing: 0.15em;
        text-transform: uppercase;
      }

      .service-card {
        background: var(--card) !important;
        border: 1px solid var(--line);
        border-radius: 10px !important;
        padding: 0.5rem !important;
      }

      .service-card:hover {
        background: var(--card-hover) !important;
        border-color: rgba(74, 222, 128, 0.25);
      }

      .service-name {
        color: var(--text);
        font-weight: 500;
      }

      .service-description {
        color: var(--muted) !important;
      }

      .service-block {
        background: transparent !important;
      }

      .service-block-value {
        color: var(--text);
        font-size: 0.95rem;
        font-weight: 300;
      }

      .service-block-label {
        color: var(--muted);
        font-size: 0.625rem;
        letter-spacing: 0.08em;
      }
    '';
  };
}
