// The link names what is shared after the "#", so the server that answers
// this page sees only "/l/". The page reads the fragment in the browser,
// sets every value as text, and loads only the cover and, when played, the
// audio, each straight from its https address in the link.
(function () {
  "use strict";
  var german = (navigator.language || "").toLowerCase().indexOf("de") === 0;
  var words = german ? {
    e: "Folge", s: "Sendung", r: "Radiosender", b: "Hörbuch", m: "Musiktitel",
    store: "Laden im App Store",
    more: "Mehr", website: "Webseite der Sendung", episodes: "Neueste Folgen",
    play: "Abspielen", pause: "Anhalten", hours: "Std.", minutes: "Min.", locale: "de-DE",
    viaJamendo: "Creative Commons, via Jamendo",
    onJamendo: "Auf Jamendo anhören",
    onArchive: "Im Internet Archive ansehen",
    archiveRights: "Diese Aufnahmen stammen aus dem Internet Archive. Ihre Rechtelage garantiert das Archiv nicht.",
    hint: "Mit Mär öffnet dieser Link direkt in der App.",
    unreadable: "Dieser Link lässt sich nicht öffnen."
  } : {
    e: "Episode", s: "Show", r: "Radio station", b: "Audiobook", m: "Track",
    store: "Download on the App Store",
    more: "More", website: "Website of the show", episodes: "Latest episodes",
    play: "Play", pause: "Pause", hours: "h", minutes: "min", locale: "en-US",
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
  document.getElementById("badge").alt = words.store;

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

  // A show or an episode reads its feed in this browser, from the address
  // in the link; maer.fm learns nothing of it. Everything from the feed is
  // set as text, no picture of it loads, and an address with access in it
  // is left out. A feed that does not answer, or that its server does not
  // let a page read, leaves the page as it is, without a word.
  var FEED_LIMIT = 8 * 1024 * 1024;
  if ((link.k === "s" || link.k === "e") && link.f.indexOf("https://") === 0) {
    readFeed(link.f).then(function (feed) { if (feed) { showFeed(feed, link); } }, function () {});
  }

  function readFeed(address) {
    return fetch(address, { credentials: "omit", referrerPolicy: "no-referrer" }).then(function (response) {
      if (!response.ok) { return null; }
      return response.text().then(function (text) {
        return text.length > FEED_LIMIT ? null : parseFeed(text);
      });
    });
  }

  // The channel of an RSS feed, its description, website and items; null
  // for anything else.
  function parseFeed(text) {
    var doc = new DOMParser().parseFromString(text, "application/xml");
    if (doc.getElementsByTagName("parsererror").length > 0) { return null; }
    var rss = doc.documentElement;
    var channel = rss && rss.nodeName === "rss" ? child(rss, "channel") : null;
    if (!channel) { return null; }
    var items = [];
    for (var node = channel.firstElementChild; node; node = node.nextElementSibling) {
      if (node.nodeName === "item") { items.push(node); }
    }
    return {
      description: plain(childText(channel, "itunes:summary") || childText(channel, "description")),
      website: childText(channel, "link"),
      items: items
    };
  }

  function child(parent, name) {
    for (var node = parent.firstElementChild; node; node = node.nextElementSibling) {
      if (node.nodeName === name) { return node; }
    }
    return null;
  }

  function childText(parent, name) {
    var node = child(parent, name);
    return node ? node.textContent.trim() : "";
  }

  // The text of a description that may hold HTML. The HTML goes into a
  // document of its own that is never shown, where nothing runs or loads,
  // and only its text comes out, with its paragraphs and line breaks.
  function plain(html) {
    if (!html) { return ""; }
    var doc = new DOMParser().parseFromString(html, "text/html");
    if (!doc.body) { return ""; }
    var breaks = doc.body.querySelectorAll("br");
    for (var i = 0; i < breaks.length; i++) { breaks[i].replaceWith("\n"); }
    var blocks = doc.body.querySelectorAll("p, div, li");
    for (var j = 0; j < blocks.length; j++) { blocks[j].append("\n\n"); }
    return doc.body.textContent.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  // An address the page may open or play: https, or http for a website,
  // and no access in it.
  function usable(address, schemes) {
    if (!address) { return false; }
    for (var i = 0; i < schemes.length; i++) {
      if (address.indexOf(schemes[i]) === 0) { return !carriesAccess(address); }
    }
    return false;
  }

  function showFeed(feed, link) {
    if (link.k === "s") {
      showAbout(feed.description, usable(feed.website, ["https://", "http://"]) ? feed.website : null);
      showEpisodes(feed.items);
    } else {
      var item = null;
      for (var i = 0; i < feed.items.length && !item; i++) {
        if (childText(feed.items[i], "guid") === link.g) { item = feed.items[i]; }
      }
      if (item) {
        showAbout(plain(childText(item, "content:encoded") || childText(item, "itunes:summary") || childText(item, "description")), null);
      }
    }
  }

  // The description, cut to a few lines with "More" when it is longer, and
  // the website of the show.
  function showAbout(text, website) {
    if (!text && !website) { return; }
    var about = document.getElementById("about");
    var description = document.getElementById("description");
    about.hidden = false;
    if (text) {
      description.textContent = text;
      description.classList.add("short");
      if (description.scrollHeight > description.clientHeight + 1) {
        var more = document.getElementById("more");
        more.textContent = words.more;
        more.hidden = false;
        more.addEventListener("click", function () {
          description.classList.remove("short");
          more.hidden = true;
        });
      } else {
        description.classList.remove("short");
      }
    } else {
      description.hidden = true;
    }
    if (website) {
      var site = document.getElementById("website");
      site.href = website;
      site.textContent = words.website;
      site.hidden = false;
    }
  }

  // The ten newest episodes with date, length and a play button; an
  // episode whose audio is not https or carries access is left out.
  function showEpisodes(items) {
    var rows = [];
    for (var i = 0; i < items.length; i++) {
      var enclosure = child(items[i], "enclosure");
      var audio = enclosure ? enclosure.getAttribute("url") : "";
      if (!usable(audio, ["https://"])) { continue; }
      rows.push({
        title: childText(items[i], "title"),
        date: Date.parse(childText(items[i], "pubDate")),
        length: childText(items[i], "itunes:duration"),
        audio: audio
      });
    }
    rows.sort(function (a, b) { return (b.date || 0) - (a.date || 0); });
    rows = rows.slice(0, 10);
    if (rows.length === 0) { return; }
    document.getElementById("episodes-title").textContent = words.episodes;
    var list = document.getElementById("list");
    for (var j = 0; j < rows.length; j++) { list.appendChild(episodeRow(rows[j])); }
    document.getElementById("episodes").hidden = false;
  }

  function episodeRow(row) {
    var item = document.createElement("li");
    var text = document.createElement("div");
    text.className = "episode";
    var title = document.createElement("p");
    title.className = "episode-title";
    title.textContent = row.title;
    var meta = document.createElement("p");
    meta.className = "episode-meta";
    var parts = [];
    if (row.date) {
      parts.push(new Date(row.date).toLocaleDateString(words.locale, { day: "numeric", month: "short", year: "numeric" }));
    }
    var length = duration(row.length);
    if (length) { parts.push(length); }
    meta.textContent = parts.join(" · ");
    text.appendChild(title);
    text.appendChild(meta);
    var button = document.createElement("button");
    button.type = "button";
    button.className = "play";
    button.textContent = "▶";
    button.setAttribute("aria-label", words.play + ": " + row.title);
    button.setAttribute("aria-pressed", "false");
    button.addEventListener("click", function () { playEpisode(row, button); });
    item.appendChild(text);
    item.appendChild(button);
    return item;
  }

  // One player for the page: a row plays in it, and pressing the playing
  // row again pauses it.
  function playEpisode(row, button) {
    var player = document.getElementById("audio");
    if (player.src === row.audio && !player.paused) {
      player.pause();
      return;
    }
    var pressed = document.querySelectorAll(".play[aria-pressed=\"true\"]");
    for (var i = 0; i < pressed.length; i++) { pressed[i].setAttribute("aria-pressed", "false"); pressed[i].textContent = "▶"; }
    if (player.src !== row.audio) { player.src = row.audio; }
    player.hidden = false;
    player.play();
    button.setAttribute("aria-pressed", "true");
    button.textContent = "❚❚";
    player.onpause = function () { button.setAttribute("aria-pressed", "false"); button.textContent = "▶"; };
    player.onplay = function () { button.setAttribute("aria-pressed", "true"); button.textContent = "❚❚"; };
  }

  // "3600", "61:30" or "1:01:30" as "1 h 1 min" or "42 min".
  function duration(raw) {
    if (!raw || !/^[0-9:]+$/.test(raw)) { return ""; }
    var seconds = 0;
    var parts = raw.split(":");
    for (var i = 0; i < parts.length; i++) { seconds = seconds * 60 + Number(parts[i]); }
    if (!seconds) { return ""; }
    var hours = Math.floor(seconds / 3600);
    var minutes = Math.round((seconds % 3600) / 60);
    if (hours && minutes === 60) { hours += 1; minutes = 0; }
    if (!hours) { return Math.max(1, minutes) + " " + words.minutes; }
    return hours + " " + words.hours + (minutes ? " " + minutes + " " + words.minutes : "");
  }
})();
