(function () {
  "use strict";

  function initOptionsSearch() {
    // Only activate on pages containing option headings
    var headings = document.querySelectorAll("h2");
    var optionHeadings = [];
    for (var i = 0; i < headings.length; i++) {
      var text = headings[i].textContent || "";
      if (/^(decknix\.|programs\..*\.decknix\.)/.test(text)) {
        optionHeadings.push(headings[i]);
      }
    }
    if (optionHeadings.length === 0) return;

    // Collect sections: each section is an h2 plus all siblings until the next h2
    var sections = [];
    for (var j = 0; j < optionHeadings.length; j++) {
      var h2 = optionHeadings[j];
      var els = [h2];
      var sibling = h2.nextElementSibling;
      while (sibling && sibling.tagName !== "H2") {
        els.push(sibling);
        sibling = sibling.nextElementSibling;
      }
      sections.push({ heading: h2, elements: els, text: h2.textContent.toLowerCase() });
    }

    // Build search UI
    var container = document.createElement("div");
    container.className = "options-search";
    container.style.cssText =
      "margin-bottom:1.5em;padding:0.75em 1em;background:var(--sidebar-bg);border:1px solid var(--sidebar-separator);border-radius:6px;display:flex;align-items:center;gap:0.75em;flex-wrap:wrap;";

    var input = document.createElement("input");
    input.type = "text";
    input.placeholder = "Filter options\u2026";
    input.style.cssText =
      "flex:1;min-width:200px;padding:0.4em 0.6em;font-size:0.95em;border:1px solid var(--sidebar-separator);border-radius:4px;background:var(--bg);color:var(--fg);";

    var count = document.createElement("span");
    count.style.cssText = "font-size:0.85em;color:var(--sidebar-fg);white-space:nowrap;";
    count.textContent = sections.length + " of " + sections.length + " options";

    container.appendChild(input);
    container.appendChild(count);

    // Insert before the first option heading (after any intro content)
    var firstH2 = optionHeadings[0];
    firstH2.parentNode.insertBefore(container, firstH2);

    // Filter logic
    function filterOptions() {
      var query = input.value.toLowerCase().trim();
      var visible = 0;
      for (var k = 0; k < sections.length; k++) {
        var match = query === "" || sections[k].text.indexOf(query) !== -1;
        var display = match ? "" : "none";
        for (var m = 0; m < sections[k].elements.length; m++) {
          sections[k].elements[m].style.display = display;
        }
        if (match) visible++;
      }
      count.textContent = visible + " of " + sections.length + " options";
    }

    input.addEventListener("input", filterOptions);
  }

  // Run after DOM is ready
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initOptionsSearch);
  } else {
    initOptionsSearch();
  }
})();

