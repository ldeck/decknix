(function () {
  "use strict";

  /**
   * Parses simple markup in <pre class="sb-markup"> blocks.
   * Format: {class}text{/} or {class1 class2}text{/}
   */
  function parseSidebarMarkup() {
    var blocks = document.querySelectorAll('pre.sb-markup');
    blocks.forEach(function (block) {
      var content = block.innerHTML;
      
      // We use a regex to find {tags}text{/}
      // 1. { ( [^}]+ ) }  -> Group 1: the classes
      // 2. ( [^{]+ )       -> Group 2: the text (non-greedy, but simplified)
      // 3. { / }           -> The closing tag
      // This is a simplified parser. It doesn't handle nested tags (not needed for this).
      
      var regex = /\{([^}/]+)\}([\s\S]*?)\{\/\}/g;
      var newContent = content.replace(regex, function (match, classes, text) {
        return '<span class="' + classes.trim() + '">' + text + '</span>';
      });

      block.innerHTML = newContent;
      block.style.visibility = 'visible';
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", parseSidebarMarkup);
  } else {
    parseSidebarMarkup();
  }
})();
