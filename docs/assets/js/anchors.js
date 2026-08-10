// Add a copy-link button to section headings (h2–h4) so readers can
// easily grab a deep link to a specific section, e.g. /#data-layout.
(function () {
  "use strict";

  // Fallback for browsers without the async Clipboard API (non-secure
  // contexts, older Safari). `document.execCommand` is deprecated but still
  // the only reliable non-API path.
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      try {
        document.execCommand("copy") ? resolve() : reject(new Error("copy failed"));
      } catch (err) {
        reject(err);
      }
      document.body.removeChild(textarea);
    });
  }

  var LINK_ICON =
    '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>' +
    '<path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>';

  var CHECK_ICON =
    '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<path d="M20 6 9 17l-5-5"/></svg>';

  function addAnchorButtons() {
    var pageUrl = location.href.split("#")[0];
    document.querySelectorAll("h2[id], h3[id], h4[id]").forEach(function (heading) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "anchor-link";
      button.title = "Copy link to this section";
      button.setAttribute("aria-label", "Copy link to this section");
      button.innerHTML = LINK_ICON;

      button.addEventListener("click", function () {
        copyText(pageUrl + "#" + heading.id).then(
          function () {
            button.classList.add("copied");
            button.title = "Copied!";
            button.setAttribute("aria-label", "Link copied");
            button.innerHTML = CHECK_ICON;
            setTimeout(function () {
              button.classList.remove("copied");
              button.title = "Copy link to this section";
              button.setAttribute("aria-label", "Copy link to this section");
              button.innerHTML = LINK_ICON;
            }, 1500);
          },
          function () {
            // Clipboard unavailable — ignore silently.
          }
        );
      });

      heading.appendChild(button);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", addAnchorButtons);
  } else {
    addAnchorButtons();
  }
})();
