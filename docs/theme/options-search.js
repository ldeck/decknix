(function () {
  "use strict";

  var REPO_URL = "https://github.com/ldeck/decknix/blob/main/modules/";
  var allOptions = {};
  var currentChannel = "";

  function initOptionsHub() {
    var list = document.getElementById("options-list");
    if (!list) return; // not on the options page

    var search = document.getElementById("options-search");
    var channel = document.getElementById("options-channel");
    var count = document.getElementById("options-count");

    // Restore saved channel preference
    var saved = localStorage.getItem("decknix-options-channel");
    if (saved && channel.querySelector('option[value="' + saved + '"]')) {
      channel.value = saved;
    }

    function loadChannel(ch) {
      currentChannel = ch;
      localStorage.setItem("decknix-options-channel", ch);
      list.innerHTML = '<p style="color:var(--sidebar-fg);font-style:italic;">Loading options…</p>';

      fetch("data/options-" + ch + ".json")
        .then(function (r) {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        })
        .then(function (data) {
          allOptions = data;
          render();
        })
        .catch(function (err) {
          list.innerHTML = '<p style="color:#c33;">Failed to load options for <b>' + ch +
            '</b>: ' + err.message + '</p>';
          count.textContent = "";
        });
    }

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

    function render() {
      var query = (search.value || "").toLowerCase().trim();
      var keys = Object.keys(allOptions).sort();
      var html = [];
      var visible = 0;

      for (var i = 0; i < keys.length; i++) {
        var name = keys[i];
        var opt = allOptions[name];
        var desc = opt.description || "";
        var searchText = (name + " " + desc).toLowerCase();

        if (query && searchText.indexOf(query) === -1) continue;
        visible++;

        var defVal = formatLiteral(opt["default"]);
        var exVal = formatLiteral(opt.example);
        var typeStr = opt.type || "unknown";

        // Build declaration links
        var declLinks = (opt.declarations || []).map(function (d) {
          return '<a href="' + REPO_URL + escapeHtml(d) + '" target="_blank" rel="noopener">' +
            escapeHtml(d) + '</a>';
        }).join(", ");

        html.push(
          '<div class="option-card" style="margin-bottom:1.2em;padding:0.8em 1em;border:1px solid var(--sidebar-separator);border-radius:6px;background:var(--bg);">' +
            '<h3 style="margin:0 0 0.3em 0;font-size:1em;font-family:var(--mono-font,monospace);">' +
              '<a id="' + escapeHtml(name) + '" href="#' + escapeHtml(name) + '" style="color:var(--links);">' +
                escapeHtml(name) +
              '</a>' +
            '</h3>' +
            (desc ? '<p style="margin:0 0 0.5em 0;font-size:0.92em;">' + escapeHtml(desc) + '</p>' : '') +
            '<table style="font-size:0.85em;border-collapse:collapse;width:100%;">' +
              '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Type</td>' +
                '<td style="padding:2px 0;"><code>' + escapeHtml(typeStr) + '</code></td></tr>' +
              (defVal ? '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Default</td>' +
                '<td style="padding:2px 0;"><code style="white-space:pre-wrap;">' + escapeHtml(defVal) + '</code></td></tr>' : '') +
              (exVal ? '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Example</td>' +
                '<td style="padding:2px 0;"><code style="white-space:pre-wrap;">' + escapeHtml(exVal) + '</code></td></tr>' : '') +
              (declLinks ? '<tr><td style="padding:2px 8px 2px 0;font-weight:600;white-space:nowrap;vertical-align:top;">Declared in</td>' +
                '<td style="padding:2px 0;">' + declLinks + '</td></tr>' : '') +
            '</table>' +
          '</div>'
        );
      }

      list.innerHTML = html.length > 0 ? html.join("") :
        '<p style="color:var(--sidebar-fg);font-style:italic;">No options match "' + escapeHtml(query) + '"</p>';
      count.textContent = visible + " of " + keys.length + " options";

      // Scroll to hash if present
      if (window.location.hash) {
        var target = document.getElementById(window.location.hash.slice(1));
        if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
      }
    }

    // Debounced search
    var timer = null;
    search.addEventListener("input", function () {
      clearTimeout(timer);
      timer = setTimeout(render, 150);
    });

    channel.addEventListener("change", function () {
      loadChannel(channel.value);
    });

    // Initial load
    loadChannel(channel.value);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initOptionsHub);
  } else {
    initOptionsHub();
  }
})();

