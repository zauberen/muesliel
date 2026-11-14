// Confirmation prompts for server-rendered forms (kept out of inline
// handlers so the Content-Security-Policy can forbid inline script).
document.addEventListener("submit", function (e) {
  var msg = e.target.getAttribute("data-confirm");
  if (msg && !window.confirm(msg)) e.preventDefault();
});
