function storageGet(key) {
  try { return localStorage.getItem(key); } catch (e) { return null; }
}

function storageSet(key, val) {
  try { localStorage.setItem(key, val); } catch (e) {}
}

document.addEventListener("DOMContentLoaded", function() {
  var root = document.documentElement;
  var btn = document.getElementById("theme-toggle");

  function paint() {
    btn.textContent = root.dataset.theme === "dark" ? "☀️" : "🌙";
  }

  if (btn) {
    paint();
    btn.addEventListener("click", function() {
      root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
      storageSet("theme", root.dataset.theme);
      paint();
    });
  }

  document.querySelectorAll(".side details[data-key]").forEach(function(d) {
    var key = "side-" + d.dataset.key;
    if (storageGet(key) === "closed") d.open = false;
    d.addEventListener("toggle", function() {
      storageSet(key, d.open ? "open" : "closed");
    });
  });
});
