(function () {
  "use strict";

  var REPO_URL = "https://github.com/ldeck/decknix/blob/main/modules/";
  var allOptions = {};
  var teamPackages = null; // loaded from org-packages.json if present

  /* ── helpers ── */

  function escapeHtml(s) {
    var div = document.createElement("div");
    div.appendChild(document.createTextNode(s));
    return div.innerHTML;
  }

  function formatLiteral(val) {
    if (!val) return "";
    if (val._type === "literalExpression") return val.text || "";
    if (val._type === "literalMD") return val.text || "";
    if (typeof val === "string") return val;
    return JSON.stringify(val);
  }

  function card(icon, title, desc, links) {
    var h = '<div style="margin-bottom:1.2em;padding:0.8em 1em;border:1px solid var(--sidebar-separator);border-radius:6px;background:var(--bg);">' +
      '<h3 style="margin:0 0 0.3em 0;font-size:1.05em;">' + icon + " " + escapeHtml(title) + '</h3>' +
      '<p style="margin:0 0 0.6em 0;font-size:0.92em;">' + escapeHtml(desc) + '</p>';
    if (links && links.length) {
      h += '<ul style="margin:0;padding-left:1.2em;">';
      for (var i = 0; i < links.length; i++) {
        h += '<li style="margin-bottom:0.3em;"><a href="' + escapeHtml(links[i].url) +
          '" target="_blank" rel="noopener" style="color:var(--links);">' +
          escapeHtml(links[i].label) + '</a>';
        if (links[i].note) h += ' <span style="font-size:0.85em;color:var(--sidebar-fg);">\u2014 ' + escapeHtml(links[i].note) + '</span>';
        h += '</li>';
      }
      h += '</ul>';
    }
    return h + '</div>';
  }

  function lsGet(key) { try { return localStorage.getItem(key); } catch (_) { return null; } }
  function lsSet(key, val) { try { localStorage.setItem(key, val); } catch (_) {} }

  /* ── static tab renderers ── */

  function renderHomeManager(el) {
    el.innerHTML =
      '<p style="margin-bottom:1em;">home-manager manages per-user programs and dotfiles declaratively. ' +
      'Decknix wraps many home-manager options behind <code>decknix.*</code> for convenience, but you ' +
      'can always set any <code>home-manager</code> option directly in your <code>home.nix</code>.</p>' +
      card("\ud83c\udfe0", "Searchable Options", "Full home-manager option reference with search.", [
        { url: "https://home-manager-options.extranix.com/", label: "home-manager options search", note: "community-maintained, searchable" },
        { url: "https://nix-community.github.io/home-manager/options.xhtml", label: "Official option appendix", note: "complete but less searchable" }
      ]) +
      card("\ud83d\udcd6", "Documentation", "Guides, release notes, and module source.", [
        { url: "https://nix-community.github.io/home-manager/", label: "home-manager manual" },
        { url: "https://github.com/nix-community/home-manager", label: "GitHub repository" }
      ]) +
      card("\ud83d\udca1", "Common Options", "Frequently used options you can set alongside decknix.", [
        { url: "https://home-manager-options.extranix.com/?query=programs.git", label: "programs.git.*", note: "Git configuration" },
        { url: "https://home-manager-options.extranix.com/?query=programs.zsh", label: "programs.zsh.*", note: "Zsh shell" },
        { url: "https://home-manager-options.extranix.com/?query=programs.ssh", label: "programs.ssh.*", note: "SSH client config" },
        { url: "https://home-manager-options.extranix.com/?query=home.packages", label: "home.packages", note: "user-level packages" },
        { url: "https://home-manager-options.extranix.com/?query=home.file", label: "home.file.*", note: "arbitrary dotfiles" }
      ]);
  }

  function renderNixDarwin(el) {
    el.innerHTML =
      '<p style="margin-bottom:1em;">nix-darwin manages macOS system-level configuration: system defaults, ' +
      'launch daemons, fonts, Homebrew integration, and more. Decknix uses nix-darwin under the hood for ' +
      'all <code>decknix.system.*</code> options.</p>' +
      card("\ud83c\udf4e", "Options Reference", "Browse all nix-darwin options.", [
        { url: "https://daiderd.com/nix-darwin/manual/index.html", label: "nix-darwin manual & options", note: "official reference" },
        { url: "https://searchix.alanpearce.eu/options/darwin/search", label: "Searchix (nix-darwin)", note: "community search tool" }
      ]) +
      card("\ud83d\udcd6", "Documentation & Source", "Guides and module source code.", [
        { url: "https://github.com/LnL7/nix-darwin", label: "GitHub repository" },
        { url: "https://github.com/LnL7/nix-darwin/tree/master/modules", label: "Module source", note: "browse available modules" }
      ]) +
      card("\ud83d\udca1", "Common Options", "Frequently used nix-darwin options.", [
        { url: "https://searchix.alanpearce.eu/options/darwin/search?query=system.defaults", label: "system.defaults.*", note: "macOS system preferences" },
        { url: "https://searchix.alanpearce.eu/options/darwin/search?query=homebrew", label: "homebrew.*", note: "Homebrew integration" },
        { url: "https://searchix.alanpearce.eu/options/darwin/search?query=environment.systemPackages", label: "environment.systemPackages", note: "system-wide packages" },
        { url: "https://searchix.alanpearce.eu/options/darwin/search?query=services", label: "services.*", note: "launch daemons & agents" },
        { url: "https://searchix.alanpearce.eu/options/darwin/search?query=fonts", label: "fonts.*", note: "system fonts" }
      ]);
  }

  function renderPackagesTab(el) {
    el.innerHTML =
      '<p style="margin-bottom:1em;">Nix packages (nixpkgs) is the largest package repository in the world. ' +
      'Use the search tools below to find packages available for installation via ' +
      '<code>home.packages</code> or <code>environment.systemPackages</code>.</p>' +
      card("\ud83d\udce6", "Package Search", "Find any of 100,000+ packages in nixpkgs.", [
        { url: "https://search.nixos.org/packages", label: "search.nixos.org/packages", note: "official NixOS package search" },
        { url: "https://searchix.alanpearce.eu/packages/nixpkgs/search", label: "Searchix packages", note: "alternative search with more metadata" }
      ]) +
      card("\ud83d\udcd6", "How Packages Work in Decknix", "Decknix installs packages at two levels.", [
        { url: "https://search.nixos.org/packages", label: "User packages \u2192 home.packages", note: "per-user, managed by home-manager" },
        { url: "https://search.nixos.org/packages", label: "System packages \u2192 environment.systemPackages", note: "system-wide, managed by nix-darwin" }
      ]) +
      '<div style="margin-bottom:1.2em;padding:0.8em 1em;border:1px solid var(--sidebar-separator);border-radius:6px;background:var(--bg);">' +
        '<h3 style="margin:0 0 0.3em 0;font-size:1.05em;">\ud83d\udca1 Tip: Package Resolution Order</h3>' +
        '<p style="margin:0;font-size:0.92em;">When adding a package to your config, decknix resolves from:</p>' +
        '<ol style="margin:0.5em 0 0 0;padding-left:1.5em;font-size:0.92em;">' +
          '<li><strong>nixpkgs</strong> (stable or unstable) \u2014 preferred</li>' +
          '<li><strong>nix-casks</strong> \u2014 fallback for macOS GUI apps not in nixpkgs</li>' +
          '<li><strong>Manual install</strong> \u2014 last resort</li>' +
        '</ol>' +
      '</div>';
  }

  function renderNixCasks(el) {
    el.innerHTML =
      '<p style="margin-bottom:1em;">nix-casks packages Homebrew Casks as Nix derivations, giving you ' +
      "macOS GUI applications (like browsers, editors, utilities) that aren't available in nixpkgs \u2014 " +
      'all managed declaratively through Nix.</p>' +
      card("\ud83c\udf7a", "nix-casks Repository", "Browse available casks and documentation.", [
        { url: "https://github.com/jacekszymanski/nix-casks", label: "GitHub: nix-casks", note: "source repository" }
      ]) +
      card("\ud83d\udca1", "When to Use nix-casks", "Use nix-casks when a macOS app isn't in nixpkgs.", []) +
      '<div style="margin-bottom:1.2em;padding:0.8em 1em;border:1px solid var(--sidebar-separator);border-radius:6px;background:var(--bg);">' +
        '<h3 style="margin:0 0 0.3em 0;font-size:1.05em;">\ud83d\udccb Common Examples</h3>' +
        '<table style="font-size:0.9em;border-collapse:collapse;width:100%;">' +
          '<tr style="border-bottom:1px solid var(--sidebar-separator);">' +
            '<th style="text-align:left;padding:4px 12px 4px 0;">App</th>' +
            '<th style="text-align:left;padding:4px 12px 4px 0;">nixpkgs</th>' +
            '<th style="text-align:left;padding:4px 0;">nix-casks</th></tr>' +
          '<tr><td style="padding:3px 12px 3px 0;"><code>firefox</code></td><td style="padding:3px 12px 3px 0;">\u2705 available</td><td style="padding:3px 0;">\u2705 also available</td></tr>' +
          '<tr><td style="padding:3px 12px 3px 0;"><code>1password</code></td><td style="padding:3px 12px 3px 0;">\u274c</td><td style="padding:3px 0;">\u2705 <code>_1password</code></td></tr>' +
          '<tr><td style="padding:3px 12px 3px 0;"><code>rectangle</code></td><td style="padding:3px 12px 3px 0;">\u274c</td><td style="padding:3px 0;">\u2705 available</td></tr>' +
          '<tr><td style="padding:3px 12px 3px 0;"><code>slack</code></td><td style="padding:3px 12px 3px 0;">\u2705 (Linux)</td><td style="padding:3px 0;">\u2705 (macOS)</td></tr>' +
        '</table>' +
      '</div>';
  }

  /* ── decknix options rendering ── */

  function renderDecknixOptions(list, count, search) {
    var query = (search.value || "").toLowerCase().trim();
    var keys = Object.keys(allOptions).sort();
    var html = [];
    var visible = 0;

    for (var i = 0; i < keys.length; i++) {
      var name = keys[i];
      var opt = allOptions[name];
      var desc = opt.description || "";
      if (query && (name + " " + desc).toLowerCase().indexOf(query) === -1) continue;
      visible++;

      var defVal = formatLiteral(opt["default"]);
      var exVal = formatLiteral(opt.example);
      var typeStr = opt.type || "unknown";
      var declLinks = (opt.declarations || []).map(function (d) {
        return '<a href="' + REPO_URL + escapeHtml(d) + '" target="_blank" rel="noopener">' + escapeHtml(d) + '</a>';
      }).join(", ");

      html.push(
        '<div class="option-card" style="margin-bottom:1.2em;padding:0.8em 1em;border:1px solid var(--sidebar-separator);border-radius:6px;background:var(--bg);">' +
          '<h3 style="margin:0 0 0.3em 0;font-size:1em;font-family:var(--mono-font,monospace);">' +
            '<a id="' + escapeHtml(name) + '" href="#' + escapeHtml(name) + '" style="color:var(--links);">' + escapeHtml(name) + '</a></h3>' +
          (desc ? '<p style="margin:0 0 0.5em 0;font-size:0.92em;">' + escapeHtml(desc) + '</p>' : '') +
          '<table style="font-size:0.85em;border-collapse:collapse;width:100%;">' +
            '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Type</td><td style="padding:2px 0;"><code>' + escapeHtml(typeStr) + '</code></td></tr>' +
            (defVal ? '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Default</td><td style="padding:2px 0;"><code style="white-space:pre-wrap;">' + escapeHtml(defVal) + '</code></td></tr>' : '') +
            (exVal ? '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Example</td><td style="padding:2px 0;"><code style="white-space:pre-wrap;">' + escapeHtml(exVal) + '</code></td></tr>' : '') +
            (declLinks ? '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Declared in</td><td style="padding:2px 0;">' + declLinks + '</td></tr>' : '') +
          '</table></div>'
      );
    }

    list.innerHTML = html.length > 0 ? html.join("") :
      '<p style="color:var(--sidebar-fg);font-style:italic;">No options match "' + escapeHtml(query) + '"</p>';
    count.textContent = visible + " of " + keys.length + " options";

    if (window.location.hash) {
      var target = document.getElementById(window.location.hash.slice(1));
      if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }

  /* ── team packages rendering (from org-packages.json) ── */

  function renderTeamPackages(pkgs, listEl, countEl, searchEl, catEl) {
    var query = (searchEl.value || "").toLowerCase().trim();
    var cat = catEl.value;
    var html = [];
    var visible = 0;
    var grouped = {};

    for (var i = 0; i < pkgs.length; i++) {
      var pkg = pkgs[i];
      var searchText = (pkg.name + " " + pkg.desc + " " + pkg.cat).toLowerCase();
      if (query && searchText.indexOf(query) === -1) continue;
      if (cat && pkg.cat !== cat) continue;
      visible++;
      if (!grouped[pkg.cat]) grouped[pkg.cat] = [];
      grouped[pkg.cat].push(pkg);
    }

    var cats = Object.keys(grouped).sort();
    for (var c = 0; c < cats.length; c++) {
      var items = grouped[cats[c]];
      html.push('<h3 style="margin:1em 0 0.5em 0;font-size:1em;color:var(--sidebar-fg);">' + escapeHtml(cats[c]) +
        ' <span style="font-size:0.85em;">(' + items.length + ')</span></h3>');
      html.push('<table style="width:100%;font-size:0.9em;border-collapse:collapse;">');
      html.push('<tr style="border-bottom:1px solid var(--sidebar-separator);">' +
        '<th style="text-align:left;padding:4px 12px 4px 0;">Package</th>' +
        '<th style="text-align:left;padding:4px 12px 4px 0;">Description</th>' +
        '<th style="text-align:left;padding:4px 0;">Source</th></tr>');
      for (var p = 0; p < items.length; p++) {
        var badge = items[p].src === "nix-casks"
          ? '<span style="background:#8b5cf6;color:#fff;padding:1px 6px;border-radius:3px;font-size:0.8em;">cask</span>'
          : '<span style="background:#3b82f6;color:#fff;padding:1px 6px;border-radius:3px;font-size:0.8em;">nix</span>';
        html.push('<tr><td style="padding:3px 12px 3px 0;"><code>' + escapeHtml(items[p].name) + '</code></td>' +
          '<td style="padding:3px 12px 3px 0;">' + escapeHtml(items[p].desc) + '</td>' +
          '<td style="padding:3px 0;">' + badge + '</td></tr>');
      }
      html.push('</table>');
    }

    listEl.innerHTML = html.length > 0 ? html.join("") :
      '<p style="color:var(--sidebar-fg);font-style:italic;">No packages match your search.</p>';
    countEl.textContent = visible + " of " + pkgs.length + " packages";
  }

  /* ── main init ── */

  function initHub() {
    var hub = document.getElementById("config-hub");
    if (!hub) return;

    var tabs = hub.querySelectorAll(".hub-tab");

    // Decknix options elements
    var optList = document.getElementById("options-list");
    var optSearch = document.getElementById("options-search");
    var optChannel = document.getElementById("options-channel");
    var optCount = document.getElementById("options-count");

    // Team packages elements
    var teamBtn = document.getElementById("tab-btn-team-packages");
    var teamList = document.getElementById("team-pkg-list");
    var teamSearch = document.getElementById("team-pkg-search");
    var teamCat = document.getElementById("team-pkg-category");
    var teamCount = document.getElementById("team-pkg-count");

    // Populate static tabs
    renderHomeManager(document.getElementById("tab-home-manager"));
    renderNixDarwin(document.getElementById("tab-nix-darwin"));
    renderPackagesTab(document.getElementById("tab-packages"));
    renderNixCasks(document.getElementById("tab-nix-casks"));

    // Tab switching
    var activeStyle = "padding:0.5em 1.2em;font-size:0.95em;border:1px solid var(--sidebar-separator);border-bottom:none;border-radius:6px 6px 0 0;background:var(--bg);color:var(--fg);cursor:pointer;font-weight:600;margin-right:2px;";
    var inactiveStyle = "padding:0.5em 1.2em;font-size:0.95em;border:1px solid transparent;border-bottom:none;border-radius:6px 6px 0 0;background:var(--sidebar-bg);color:var(--sidebar-fg);cursor:pointer;margin-right:2px;";

    function switchTab(tabName) {
      var allTabs = hub.querySelectorAll(".hub-tab");
      var allPanels = hub.querySelectorAll(".hub-panel");
      for (var i = 0; i < allTabs.length; i++) {
        var isActive = allTabs[i].getAttribute("data-tab") === tabName;
        allTabs[i].style.cssText = isActive ? activeStyle : inactiveStyle;
        if (allTabs[i] === teamBtn && !teamPackages) allTabs[i].style.display = "none";
        allTabs[i].className = isActive ? "hub-tab active" : "hub-tab";
      }
      for (var j = 0; j < allPanels.length; j++) {
        allPanels[j].style.display = allPanels[j].id === "tab-" + tabName ? "" : "none";
      }
      lsSet("decknix-hub-tab", tabName);
    }

    for (var t = 0; t < tabs.length; t++) {
      tabs[t].addEventListener("click", function () {
        switchTab(this.getAttribute("data-tab"));
      });
    }

    // Try loading org-packages.json (optional — shows Team Packages tab if found)
    fetch("data/org-packages.json")
      .then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (data) {
        teamPackages = data;
        teamBtn.style.display = "";

        // Populate category dropdown
        var catSet = {};
        for (var i = 0; i < data.length; i++) catSet[data[i].cat] = true;
        var catNames = Object.keys(catSet).sort();
        for (var c = 0; c < catNames.length; c++) {
          var opt = document.createElement("option");
          opt.value = catNames[c];
          opt.textContent = catNames[c];
          teamCat.appendChild(opt);
        }

        // Wire up search/filter
        var timer2 = null;
        function refreshTeam() { renderTeamPackages(teamPackages, teamList, teamCount, teamSearch, teamCat); }
        teamSearch.addEventListener("input", function () {
          clearTimeout(timer2);
          timer2 = setTimeout(refreshTeam, 150);
        });
        teamCat.addEventListener("change", refreshTeam);
        refreshTeam();

        // If saved tab was team-packages, switch to it
        var saved = lsGet("decknix-hub-tab");
        if (saved === "team-packages") switchTab("team-packages");
      })
      .catch(function () { /* no org-packages.json — team tab stays hidden */ });

    // Restore saved tab (for non-team tabs)
    var savedTab = lsGet("decknix-hub-tab");
    if (savedTab && savedTab !== "team-packages" && document.getElementById("tab-" + savedTab)) {
      switchTab(savedTab);
    }

    // Restore saved channel
    var savedCh = lsGet("decknix-options-channel");
    if (savedCh && optChannel && optChannel.querySelector('option[value="' + savedCh + '"]')) {
      optChannel.value = savedCh;
    }

    // Decknix options loading
    function loadChannel(ch) {
      lsSet("decknix-options-channel", ch);
      if (optList) optList.innerHTML = '<p style="color:var(--sidebar-fg);font-style:italic;">Loading options\u2026</p>';

      fetch("data/options-" + ch + ".json")
        .then(function (r) {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        })
        .then(function (data) {
          allOptions = data;
          renderDecknixOptions(optList, optCount, optSearch);
        })
        .catch(function (err) {
          if (optList) optList.innerHTML = '<p style="color:#c33;">Failed to load options for <b>' + ch + '</b>: ' + err.message + '</p>';
          if (optCount) optCount.textContent = "";
        });
    }

    if (optSearch) {
      var timer = null;
      optSearch.addEventListener("input", function () {
        clearTimeout(timer);
        timer = setTimeout(function () { renderDecknixOptions(optList, optCount, optSearch); }, 150);
      });
    }
    if (optChannel) {
      optChannel.addEventListener("change", function () { loadChannel(optChannel.value); });
      loadChannel(optChannel.value);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initHub);
  } else {
    initHub();
  }
})();
