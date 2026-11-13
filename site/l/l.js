// The link names what is shared after the "#", so the server that answers
// this page sees only "/l/". The page reads the fragment in the browser,
// sets every value as text, and loads only the cover and, when played, the
// audio, each straight from its https address in the link.
(function () {
  "use strict";
  var german = (navigator.language || "").toLowerCase().indexOf("de") === 0;
  var words = german ? {
    e: "Folge", s: "Sendung", r: "Radiosender", b: "Hörbuch",
    store: "Mär im App Store",
    hint: "Mit Mär öffnet dieser Link direkt in der App.",
    unreadable: "Dieser Link lässt sich nicht öffnen."
  } : {
    e: "Episode", s: "Show", r: "Radio station", b: "Audiobook",
    store: "Get Mär on the App Store",
    hint: "With Mär, this link opens right in the app.",
    unreadable: "This link can't be opened."
  };
  document.documentElement.lang = german ? "de" : "en";
  // A link opened in the same tab changes only the fragment, and the page
  // does not load again by itself; it reads the new link from the start.
  window.addEventListener("hashchange", function () { location.reload(); });
  document.getElementById("store").textContent = words.store;

  // The form SharedLink writes: "1?" and a query of keys, each once.
  function read(fragment) {
    if (fragment.length > 4096 || fragment.indexOf("1?") !== 0) { return null; }
    var values = {};
    var pairs = fragment.slice(2).split("&");
    for (var i = 0; i < pairs.length; i++) {
      var at = pairs[i].indexOf("=");
      if (at < 0) { return null; }
      var key = pairs[i].slice(0, at);
      if (Object.prototype.hasOwnProperty.call(values, key)) { return null; }
      try { values[key] = decodeURIComponent(pairs[i].slice(at + 1)); } catch (e) { return null; }
    }
    var needs = { e: ["f", "g"], s: ["f"], r: ["i"], b: ["i"] }[values.k];
    if (!needs) { return null; }
    for (var j = 0; j < needs.length; j++) {
      if (!values[needs[j]] || !values[needs[j]].trim()) { return null; }
    }
    return values;
  }

  var link = read(location.hash.slice(1));
  if (!link) {
    document.getElementById("title").textContent = words.unreadable;
    return;
  }
  // The cover from its https address, without a referrer; a cover that does
  // not load leaves its place empty.
  if (link.c && link.c.indexOf("https://") === 0) {
    var cover = document.getElementById("cover");
    cover.addEventListener("error", function () { cover.classList.add("failed"); });
    cover.src = link.c;
    cover.hidden = false;
  }
  document.getElementById("kind").textContent = words[link.k];
  document.title = link.t ? link.t + " · Mär" : "Mär";
  if (link.t) { document.getElementById("title").textContent = link.t; }
  if (link.s) {
    var subtitle = document.getElementById("subtitle");
    subtitle.textContent = link.s;
    subtitle.hidden = false;
  }
  // Only an https address plays; the page holds no other.
  if (link.a && link.a.indexOf("https://") === 0) {
    var audio = document.getElementById("audio");
    audio.src = link.a;
    audio.hidden = false;
  }
  document.getElementById("hint").textContent = words.hint;
})();
