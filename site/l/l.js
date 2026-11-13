// The link names what is shared after the "#", so the server that answers
// this page sees only "/l/". The page reads the fragment in the browser,
// sets every value as text, and loads only the cover and, when played, the
// audio, each straight from its https address in the link.
(function () {
  "use strict";
  var german = (navigator.language || "").toLowerCase().indexOf("de") === 0;
  var words = german ? {
    e: "Folge", s: "Sendung", r: "Radiosender", b: "Hörbuch", m: "Musiktitel",
    store: "Mär im App Store",
    viaJamendo: "Creative Commons, via Jamendo",
    onJamendo: "Auf Jamendo anhören",
    onArchive: "Im Internet Archive ansehen",
    archiveRights: "Diese Aufnahmen stammen aus dem Internet Archive. Ihre Rechtelage garantiert das Archiv nicht.",
    hint: "Mit Mär öffnet dieser Link direkt in der App.",
    unreadable: "Dieser Link lässt sich nicht öffnen."
  } : {
    e: "Episode", s: "Show", r: "Radio station", b: "Audiobook", m: "Track",
    store: "Get Mär on the App Store",
    viaJamendo: "Creative Commons, via Jamendo",
    onJamendo: "Listen on Jamendo",
    onArchive: "View on the Internet Archive",
    archiveRights: "These recordings come from the Internet Archive, which does not guarantee their rights status.",
    hint: "With Mär, this link opens right in the app.",
    unreadable: "This link can't be opened."
  };
  document.documentElement.lang = german ? "de" : "en";
  // A link opened in the same tab changes only the fragment, and the page
  // does not load again by itself; it reads the new link from the start.
  window.addEventListener("hashchange", function () { location.reload(); });
  document.getElementById("store").textContent = words.store;

  // The two forms of a free music track, as SharedLink checks them.
  var JAMENDO = /^jam:([0-9]+)$/;
  var ARCHIVE = /^lva:([^#]+)#[0-9]+$/;

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
    var needs = { e: ["f", "g"], s: ["f"], r: ["i"], b: ["i"], m: ["i"] }[values.k];
    if (!needs) { return null; }
    for (var j = 0; j < needs.length; j++) {
      if (!values[needs[j]] || !values[needs[j]].trim()) { return null; }
    }
    // A music track is a Jamendo track or a song of an archive.org release.
    if (values.k === "m" && !JAMENDO.test(values.i) && !ARCHIVE.test(values.i)) { return null; }
    return values;
  }

  // The question the app asks before it shares or opens a link
  // (PodcastFeedAddress.carriesAccess): an address with a user or password
  // before its host, or a query name that says access, carries access. The
  // three lists are the app's, word for word (fence in SharedLinkPageAccessTests).
  var ACCESS_PARTS = ["token", "auth", "key", "secret", "pass", "password", "passwd", "sig", "signature", "session", "sid", "freebie", "apikey"];
  var ACCESS_HARD = ["token", "secret", "password", "passwd", "passcode", "passphrase", "apikey", "signature", "pwd", "hmac"];
  var ACCESS_KEY_LEADS = ["api", "access", "auth", "secret", "private", "session", "client", "signing"];
  var ALNUM = /[\p{L}\p{N}]/u;

  function isUpper(c) { return c !== c.toLowerCase() && c === c.toUpperCase(); }
  function isLower(c) { return c !== c.toUpperCase() && c === c.toLowerCase(); }
  function has(list, word) { return list.indexOf(word) >= 0; }
  function endsWith(text, end) { return text.length >= end.length && text.slice(text.length - end.length) === end; }

  function namesAccess(name) {
    var words = [name];
    var word = "";
    var previous = "";
    for (var i = 0; i < name.length; i++) {
      var c = name.charAt(i);
      if (!ALNUM.test(c)) {
        words.push(word); word = "";
      } else {
        if (isUpper(c) && previous && isLower(previous)) { words.push(word); word = ""; }
        word += c;
      }
      previous = c;
    }
    words.push(word);
    for (var j = 0; j < words.length; j++) {
      if (has(ACCESS_PARTS, words[j].toLowerCase())) { return true; }
    }
    var joined = "";
    var lower = name.toLowerCase();
    for (var k = 0; k < lower.length; k++) {
      if (ALNUM.test(lower.charAt(k))) { joined += lower.charAt(k); }
    }
    for (var h = 0; h < ACCESS_HARD.length; h++) {
      if (joined.indexOf(ACCESS_HARD[h]) === 0 || endsWith(joined, ACCESS_HARD[h])) { return true; }
    }
    for (var l = 0; l < ACCESS_KEY_LEADS.length; l++) {
      if (endsWith(joined, ACCESS_KEY_LEADS[l] + "key")) { return true; }
    }
    return joined.indexOf("session") === 0 || endsWith(joined, "pass") || endsWith(joined, "auth");
  }

  function carriesAccess(raw) {
    if (!raw) { return false; }
    var text = raw.trim();
    var q = text.indexOf("?");
    if (q >= 0) {
      var pairs = text.slice(q + 1).split("&");
      for (var i = 0; i < pairs.length; i++) {
        var at = pairs[i].indexOf("=");
        if (at > 0 && at < pairs[i].length - 1 && namesAccess(pairs[i].slice(0, at))) { return true; }
      }
    }
    var scheme = text.indexOf("://");
    var rest = scheme >= 0 ? text.slice(scheme + 3) : text;
    var end = rest.search(/[\/?#]/);
    var authority = end >= 0 ? rest.slice(0, end) : rest;
    return authority.indexOf("@") >= 0;
  }

  var link = read(location.hash.slice(1));
  // A link with access in any of its addresses shows nothing of it.
  if (link && (carriesAccess(link.f) || carriesAccess(link.a) || carriesAccess(link.c))) { link = null; }
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
  // A free music track names its provider and its page there. A Jamendo
  // track never plays here, the page names the track on Jamendo instead;
  // a song of the Internet Archive carries the archive's rights sentence.
  var jamendo = link.k === "m" ? JAMENDO.exec(link.i) : null;
  var archive = link.k === "m" ? ARCHIVE.exec(link.i) : null;
  var source = document.getElementById("source");
  if (jamendo) {
    var provider = document.getElementById("provider");
    provider.textContent = words.viaJamendo;
    provider.hidden = false;
    source.href = "https://www.jamendo.com/track/" + jamendo[1];
    source.textContent = words.onJamendo;
    source.hidden = false;
  }
  if (archive) {
    var rights = document.getElementById("rights");
    rights.textContent = words.archiveRights;
    rights.hidden = false;
    source.href = "https://archive.org/details/" + encodeURIComponent(archive[1]);
    source.textContent = words.onArchive;
    source.hidden = false;
  }
  // Only an https address plays; the page holds no other.
  if (!jamendo && link.a && link.a.indexOf("https://") === 0) {
    var audio = document.getElementById("audio");
    audio.src = link.a;
    audio.hidden = false;
  }
  document.getElementById("hint").textContent = words.hint;
})();
