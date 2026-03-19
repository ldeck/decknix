# Configuration Hub

> Your single entry point for configuring a decknix-managed system.
> Browse framework options, or jump to upstream references for home-manager, nix-darwin, packages, and casks.

<div id="config-hub">
  <nav id="hub-tabs" style="display:flex;gap:0;margin-bottom:0;border-bottom:2px solid var(--sidebar-separator);flex-wrap:wrap;">
    <button class="hub-tab active" data-tab="decknix"
      style="padding:0.5em 1.2em;font-size:0.95em;border:1px solid var(--sidebar-separator);border-bottom:none;border-radius:6px 6px 0 0;background:var(--bg);color:var(--fg);cursor:pointer;font-weight:600;margin-right:2px;">Decknix</button>
    <button class="hub-tab" data-tab="home-manager"
      style="padding:0.5em 1.2em;font-size:0.95em;border:1px solid transparent;border-bottom:none;border-radius:6px 6px 0 0;background:var(--sidebar-bg);color:var(--sidebar-fg);cursor:pointer;margin-right:2px;">Home Manager</button>
    <button class="hub-tab" data-tab="nix-darwin"
      style="padding:0.5em 1.2em;font-size:0.95em;border:1px solid transparent;border-bottom:none;border-radius:6px 6px 0 0;background:var(--sidebar-bg);color:var(--sidebar-fg);cursor:pointer;margin-right:2px;">nix-darwin</button>
    <button class="hub-tab" data-tab="packages"
      style="padding:0.5em 1.2em;font-size:0.95em;border:1px solid transparent;border-bottom:none;border-radius:6px 6px 0 0;background:var(--sidebar-bg);color:var(--sidebar-fg);cursor:pointer;margin-right:2px;">Packages</button>
    <button class="hub-tab" data-tab="nix-casks"
      style="padding:0.5em 1.2em;font-size:0.95em;border:1px solid transparent;border-bottom:none;border-radius:6px 6px 0 0;background:var(--sidebar-bg);color:var(--sidebar-fg);cursor:pointer;margin-right:2px;">nix-casks</button>
    <!-- Team Packages tab: hidden by default, shown by JS when org-packages.json exists -->
    <button class="hub-tab" data-tab="team-packages" id="tab-btn-team-packages"
      style="display:none;padding:0.5em 1.2em;font-size:0.95em;border:1px solid transparent;border-bottom:none;border-radius:6px 6px 0 0;background:var(--sidebar-bg);color:var(--sidebar-fg);cursor:pointer;margin-right:2px;">Team Packages</button>
  </nav>

  <!-- Decknix tab (full search) -->
  <div id="tab-decknix" class="hub-panel" style="padding:1em 0;">
    <div id="options-controls" style="margin-bottom:1.5em;padding:0.75em 1em;background:var(--sidebar-bg);border:1px solid var(--sidebar-separator);border-radius:6px;display:flex;align-items:center;gap:0.75em;flex-wrap:wrap;">
      <input id="options-search" type="text" placeholder="Search decknix options…"
        style="flex:1;min-width:200px;padding:0.4em 0.6em;font-size:0.95em;border:1px solid var(--sidebar-separator);border-radius:4px;background:var(--bg);color:var(--fg);" />
      <select id="options-channel"
        style="padding:0.4em 0.6em;font-size:0.95em;border:1px solid var(--sidebar-separator);border-radius:4px;background:var(--bg);color:var(--fg);">
        <option value="unstable">nixpkgs unstable</option>
        <option value="24.11">nixpkgs 24.11</option>
      </select>
      <!-- Source filters: hidden by default, shown when org-options.json exists -->
      <span id="options-source-filters" style="display:none;font-size:0.9em;">
        <label style="cursor:pointer;margin-right:0.6em;"><input type="checkbox" id="opt-show-core" checked style="margin-right:3px;" />Core</label>
        <label style="cursor:pointer;"><input type="checkbox" id="opt-show-org" checked style="margin-right:3px;" />Org</label>
      </span>
      <span id="options-count" style="font-size:0.85em;color:var(--sidebar-fg);white-space:nowrap;"></span>
    </div>
    <div id="options-list"></div>
  </div>

  <!-- Home Manager tab -->
  <div id="tab-home-manager" class="hub-panel" style="display:none;padding:1em 0;"></div>

  <!-- nix-darwin tab -->
  <div id="tab-nix-darwin" class="hub-panel" style="display:none;padding:1em 0;"></div>

  <!-- Packages tab -->
  <div id="tab-packages" class="hub-panel" style="display:none;padding:1em 0;"></div>

  <!-- nix-casks tab -->
  <div id="tab-nix-casks" class="hub-panel" style="display:none;padding:1em 0;"></div>

  <!-- Team Packages tab (populated from org-packages.json if present) -->
  <div id="tab-team-packages" class="hub-panel" style="display:none;padding:1em 0;">
    <div id="team-pkg-controls" style="margin-bottom:1em;padding:0.75em 1em;background:var(--sidebar-bg);border:1px solid var(--sidebar-separator);border-radius:6px;display:flex;align-items:center;gap:0.75em;flex-wrap:wrap;">
      <input id="team-pkg-search" type="text" placeholder="Search team packages…"
        style="flex:1;min-width:200px;padding:0.4em 0.6em;font-size:0.95em;border:1px solid var(--sidebar-separator);border-radius:4px;background:var(--bg);color:var(--fg);" />
      <select id="team-pkg-category"
        style="padding:0.4em 0.6em;font-size:0.95em;border:1px solid var(--sidebar-separator);border-radius:4px;background:var(--bg);color:var(--fg);">
        <option value="">All categories</option>
      </select>
      <span id="team-pkg-count" style="font-size:0.85em;color:var(--sidebar-fg);white-space:nowrap;"></span>
    </div>
    <div id="team-pkg-list"></div>
  </div>

  <noscript><p>JavaScript is required for the interactive configuration hub.</p></noscript>
</div>

