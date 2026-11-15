// The start page's own parts on top of Homepage: the up count, a bar listing the values its
// highlights mark, a search, group chips and a compact view. Homepage renders in the browser and
// again on every refresh, so each part is redone on every change of the page, writing only what
// differs; a part whose element is missing is left out, and the page works without this file.
// The up count polls every 2 s instead: the status dots change only their class, which the
// observer doesn't watch.
(() => {
  const store = {
    get(key) {
      try {
        return localStorage.getItem(key);
      } catch {
        return null;
      }
    },
    set(key, value) {
      try {
        localStorage.setItem(key, value);
      } catch {
        // private windows and blocked storage: the choice lasts until the page reloads
      }
    },
  };

  const state = {
    query: "",
    group: store.get("start.group") || "All",
    view: store.get("start.view") === "compact" ? "compact" : "detailed",
  };

  const setText = (element, text) => {
    if (element.textContent !== text) element.textContent = text;
  };
  const setAttribute = (element, name, value) => {
    if (element.getAttribute(name) !== value) element.setAttribute(name, value);
  };
  const setHidden = (element, hidden) => {
    if (element.hasAttribute("data-start-hidden") !== hidden) element.toggleAttribute("data-start-hidden", hidden);
  };

  // ── up count ────────
  setInterval(() => {
    const button = document.getElementById("revalidate");
    if (!button) return;
    const all = document.querySelectorAll(".site-monitor-status").length;
    const up = document.querySelectorAll(".site-monitor-status .bg-emerald-500").length;
    let count = document.getElementById("services-up");
    if (!count) {
      count = document.createElement("span");
      count.id = "services-up";
      button.prepend(count);
    }
    setText(count, `${up}/${all}`);
    if (count.hasAttribute("data-down") !== (up < all)) count.toggleAttribute("data-down", up < all);
  }, 2000);

  // ── controls ────────
  // one bar right above the groups, made once and moved back if Homepage replaces them
  function controls(layout) {
    let root = document.getElementById("start-page");
    if (!root) {
      root = document.createElement("div");
      root.id = "start-page";
      root.innerHTML = `
        <div class="start-attention" hidden>
          <span class="start-attention-count"></span>
          <span class="start-attention-items"></span>
        </div>
        <div class="start-controls">
          <input type="search" class="start-search" placeholder="Search" aria-label="Search services">
          <div class="start-chips" role="group" aria-label="Groups"></div>
          <div class="start-view" role="group" aria-label="View">
            <button type="button" data-view="compact">Compact</button>
            <button type="button" data-view="detailed">Detailed</button>
          </div>
        </div>
        <p class="start-empty" hidden>No services match this search.</p>
      `;
      root.querySelector(".start-search").addEventListener("input", (event) => {
        state.query = event.target.value;
        update();
      });
      root.querySelector(".start-chips").addEventListener("click", (event) => {
        const chip = event.target.closest("[data-group]");
        if (!chip) return;
        state.group = chip.dataset.group;
        store.set("start.group", state.group);
        update();
      });
      root.querySelector(".start-view").addEventListener("click", (event) => {
        const button = event.target.closest("[data-view]");
        if (!button) return;
        state.view = button.dataset.view;
        store.set("start.view", state.view);
        update();
      });
    }
    if (root.nextElementSibling !== layout) layout.before(root);
    return root;
  }

  // groups that hold tiles, by the heading of their own; the groups that only hold the groups of
  // a shared row have none
  function groupsOf(layout) {
    const groups = [];
    for (const list of layout.querySelectorAll(".services-list")) {
      const tiles = [...list.children].filter((child) => child.matches("li.service"));
      const element = list.closest(".services-group");
      if (!tiles.length || !element) continue;
      const heading = [...element.querySelectorAll(".service-group-name")].find(
        (name) => name.closest(".services-group") === element,
      );
      if (heading) groups.push({ name: heading.textContent.trim(), tiles });
    }
    return groups;
  }

  function chips(container, groups, counts, selected) {
    const names = ["All", ...groups.map((group) => group.name)];
    if (container.dataset.names !== names.join("\n")) {
      container.replaceChildren(
        ...names.map((name) => {
          const chip = document.createElement("button");
          chip.type = "button";
          chip.dataset.group = name;
          const count = document.createElement("span");
          count.className = "start-count";
          chip.append(name, count);
          return chip;
        }),
      );
      container.dataset.names = names.join("\n");
    }
    for (const chip of container.children) {
      setText(chip.lastChild, String(counts.get(chip.dataset.group) ?? 0));
      setAttribute(chip, "aria-pressed", String(chip.dataset.group === selected));
    }
  }

  // ── filtering ────────
  // tiles match when every word of the search is in their name or description; a chip shows one
  // group; a group with no tile left goes, and so does a shared row with no group left
  function filter(root, layout, groups) {
    const words = state.query.toLowerCase().split(/\s+/).filter(Boolean);
    const selected = groups.some((group) => group.name === state.group) ? state.group : "All";
    const counts = new Map([["All", 0]]);
    for (const group of groups) {
      let count = 0;
      for (const tile of group.tiles) {
        const description = tile.querySelector(".service-description")?.textContent ?? "";
        const text = `${tile.dataset.name ?? ""} ${description}`.toLowerCase();
        const match = words.every((word) => text.includes(word));
        if (match) count += 1;
        setHidden(tile, !match || (selected !== "All" && group.name !== selected));
      }
      counts.set(group.name, count);
      counts.set("All", counts.get("All") + count);
    }
    for (const group of layout.querySelectorAll(".services-group")) {
      setHidden(group, !group.querySelector("li.service:not([data-start-hidden])"));
    }
    chips(root.querySelector(".start-chips"), groups, counts, selected);
    root.querySelector(".start-empty").hidden = groups.length === 0 || counts.get(selected) > 0;
  }

  // ── view ────────
  // compact hides the number blocks (_start-page.css); the attention bar still reads them
  function view(root) {
    setAttribute(document.documentElement, "data-start-view", state.view);
    for (const button of root.querySelectorAll("[data-view]")) {
      setAttribute(button, "aria-pressed", String(button.dataset.view === state.view));
    }
  }

  // ── attention ────────
  // every block a highlight marks warn or danger, as "<service> · <value> <label>" linking to its
  // service, whatever the search and chips hide
  function attention(root, layout) {
    const items = [];
    const marked = '.service-block[data-highlight-level="warn"], .service-block[data-highlight-level="danger"]';
    for (const block of layout.querySelectorAll(marked)) {
      const tile = block.closest("li.service");
      if (!tile) continue;
      const value = block.querySelector(".service-block-value")?.textContent.trim() ?? "";
      const label = block.querySelector(".service-block-label")?.textContent.trim().toLowerCase() ?? "";
      const link = tile.querySelector("a.service-title-text");
      items.push({
        text: `${tile.dataset.name} · ${value} ${label}`.trim(),
        href: link?.getAttribute("href"),
        target: link?.getAttribute("target"),
      });
    }

    const bar = root.querySelector(".start-attention");
    const list = bar.querySelector(".start-attention-items");
    const signature = JSON.stringify(items);
    if (list.dataset.items !== signature) {
      list.replaceChildren(
        ...items.map((item) => {
          const entry = document.createElement(item.href ? "a" : "span");
          entry.textContent = item.text;
          if (item.href) {
            entry.href = item.href;
            entry.rel = "noreferrer";
            if (item.target) entry.target = item.target;
          }
          return entry;
        }),
      );
      list.dataset.items = signature;
    }
    setText(bar.querySelector(".start-attention-count"), `${items.length} need attention`);
    bar.hidden = items.length === 0;
  }

  // ── updates ────────
  function update() {
    const layout = document.getElementById("layout-groups");
    if (!layout) {
      document.getElementById("start-page")?.remove();
      return;
    }
    const root = controls(layout);
    filter(root, layout, groupsOf(layout));
    view(root);
    attention(root, layout);
  }

  // one update per frame however many changes come in; an update that changes nothing causes no
  // further changes, so this settles
  let queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      update();
    });
  };
  new MutationObserver(schedule).observe(document.body, {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
    attributeFilter: ["data-highlight-level"],
  });
  schedule();
})();
