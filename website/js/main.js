(function () {
  'use strict';
  var cfg = window.JH_CONFIG || {};
  var url = (cfg.DOWNLOAD_URL || '').trim();

  // Every Download button uses the one link set in js/config.js.
  document.querySelectorAll('[data-download]').forEach(function (a) {
    if (url) {
      a.setAttribute('href', url);
      a.setAttribute('download', cfg.FILE_LABEL || '');
    } else {
      a.setAttribute('href', '#download');
      a.addEventListener('click', function () {
        var soon = document.getElementById('dlSoon');
        if (soon) soon.hidden = false;
      });
    }
  });
  var source = (cfg.SOURCE_URL || '').trim();
  if (/^https:\/\//.test(source)) {
    document.querySelectorAll('[data-source]').forEach(function (a) {
      a.setAttribute('href', source);
      a.setAttribute('rel', 'noopener');
      a.hidden = false;
    });
  }
  if (cfg.VERSION) {
    document.querySelectorAll('[data-version]').forEach(function (el) { el.textContent = 'Version ' + cfg.VERSION; });
  }
  var year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  // hero banners drop in once the desktop scene is on screen
  var stage = document.querySelector('.stage');
  if (stage) {
    if ('IntersectionObserver' in window) {
      var seen = new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting) { stage.classList.add('is-live'); seen.disconnect(); }
      }, { threshold: 0.35 });
      seen.observe(stage);
    } else {
      stage.classList.add('is-live');
    }
  }

  // nav
  var nav = document.querySelector('.nav');
  var toggle = document.getElementById('navToggle');
  var onScroll = function () { nav.classList.toggle('is-scrolled', window.scrollY > 8); };
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });
  function setMenu(open) {
    nav.classList.toggle('is-open', open);
    toggle.setAttribute('aria-expanded', String(open));
    toggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  }
  toggle.addEventListener('click', function () { setMenu(!nav.classList.contains('is-open')); });
  document.querySelectorAll('#navLinks a').forEach(function (a) {
    a.addEventListener('click', function () { setMenu(false); });
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') setMenu(false); });

  // film: the video file loads only when someone presses play
  var frame = document.getElementById('filmFrame');
  var video = document.getElementById('filmVideo');
  var started = false;
  function play() {
    if (!started) {
      video.src = window.matchMedia('(max-width: 900px)').matches ? video.dataset.srcSd : video.dataset.srcHd;
      video.controls = true;
      started = true;
    }
    frame.classList.add('is-playing');
    var p = video.play();
    if (p && p.catch) p.catch(function () { frame.classList.remove('is-playing'); });
  }
  document.querySelectorAll('[data-play]').forEach(function (b) {
    b.addEventListener('click', function (e) {
      if (b.tagName === 'A') {
        e.preventDefault();
        frame.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }
      play();
    });
  });
  video.addEventListener('ended', function () { frame.classList.remove('is-playing'); });

  // screenshot tabs
  document.querySelectorAll('[data-tabs]').forEach(function (box) {
    var tabs = Array.prototype.slice.call(box.querySelectorAll('[data-tab]'));
    var panes = box.querySelectorAll('[data-pane]');
    function show(i, focus) {
      tabs.forEach(function (t, n) {
        var on = n === i;
        t.setAttribute('aria-selected', String(on));
        t.tabIndex = on ? 0 : -1;
        if (on && focus) t.focus();
      });
      panes.forEach(function (p) { p.classList.toggle('is-on', p.dataset.pane === String(i)); });
    }
    tabs.forEach(function (t, n) {
      t.addEventListener('click', function () { show(n); });
      t.addEventListener('keydown', function (e) {
        if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
          e.preventDefault();
          show((n + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length, true);
        }
      });
    });
  });
})();
