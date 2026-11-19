/* nig-web: Nig for web pages. Runs in Nig's own content world.
 *
 * The same colour rules as NigMapRGB in Sources/Tweak.m, applied per
 * element from its computed style, as inline !important declarations Nig
 * records and puts back. Images, video, canvas and large SVG are left
 * alone; text is lightened only where its backdrop is dark.
 *
 * Embedded into Sources/NigWebScript.h by Web/embed.py: no double quotes
 * and no backslashes in this file.
 */
(function () {
  'use strict';
  var G = globalThis;
  if (G.__nigWeb) return;

  var DARK = 0, LIGHT = 1, MEDIA = 2;
  var TEXT = 0, BG = 1, BORDER = 2;
  var SVGNS = 'http://www.w3.org/2000/svg';
  var SKIP = {IMG: 1, VIDEO: 1, CANVAS: 1, IFRAME: 1, FRAME: 1, EMBED: 1, OBJECT: 1, PICTURE: 1,
              SOURCE: 1, AUDIO: 1, TRACK: 1, SCRIPT: 1, STYLE: 1, LINK: 1, META: 1, HEAD: 1,
              TITLE: 1, NOSCRIPT: 1, TEMPLATE: 1, BR: 1, WBR: 1};
  var SIDES = ['top', 'right', 'bottom', 'left'];
  var SIG = ['color', 'background-color', 'background-image', 'background', 'border-color',
             'border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color',
             'fill', 'stroke', '-webkit-text-fill-color'];
  var OPTS = {childList: true, subtree: true, attributes: true,
              attributeFilter: ['class', 'style', 'id', 'hidden', 'open']};

  var active = false;
  var rec = new WeakMap();      /* element -> { p: {prop: [orig, prio, ours]}, b, co, cout, sig } */
  var touched = new Set();      /* elements carrying Nig declarations */
  var watched = new WeakSet();  /* shadow roots observed */
  var observer = null, pending = new Set(), scheduled = false, full = false;

  /* Colour maths: a port of NigMapRGB. */
  function hue2rgb(p, q, t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }
  function hsl2rgb(h, s, l) {
    if (s <= 0) return [l, l, l];
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    return [hue2rgb(p, q, h + 1 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1 / 3)];
  }
  function rgb2hsl(r, g, b) {
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, h = 0, s = 0;
    if (mx !== mn) {
      var d = mx - mn;
      s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
      if (mx === r) h = (g - b) / d + (g < b ? 6 : 0);
      else if (mx === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
    }
    return [h, s, l];
  }
  function mapRGB(role, r, g, b) {
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), x = rgb2hsl(r, g, b);
    var h = x[0], s = x[1], l = x[2], chroma = mx - mn, hsv = mx > 0.0001 ? chroma / mx : 0, v, t, nl;
    if (role === TEXT) {
      if (l >= 0.6) return null;
      t = l / 0.6;
      if (chroma < 0.1 || hsv < 0.25) { v = 0.95 - 0.30 * t; return [v, v, v]; }
      nl = 0.72 - 0.08 * t;
      return hsl2rgb(h, Math.min(s, 0.92), nl);
    }
    if (role === BG) {
      if (chroma < 0.1 || hsv < 0.3) return l > 0.3 ? [0.1, 0.1, 0.1] : null;
      if (l <= 0.62) return null;
      nl = Math.min(Math.max(1 - l, 0.14), 0.45);
      return hsl2rgb(h, s * 0.75, nl);
    }
    if (chroma < 0.1 || hsv < 0.3) {
      if (l <= 0.45) return null;
      v = 0.15 + (1 - l) * 0.45;
      return [v, v, v];
    }
    return mapRGB(BG, r, g, b);
  }
  function luma(c) { return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; }

  /* Computed colours come as rgb(r, g, b) or rgba(r, g, b, a); anything
     else (display-p3, keywords) is left as it is. */
  function parse(s) {
    if (!s) return null;
    var i = s.indexOf('('), j = s.lastIndexOf(')');
    if (i < 0 || j < i) return null;
    var fn = s.slice(0, i);
    if (fn !== 'rgb' && fn !== 'rgba') return null;
    var p = s.slice(i + 1, j).split(',').join(' ').split('/').join(' ').split(' ')
             .filter(function (x) { return x.length > 0; });
    if (p.length < 3) return null;
    var a = 1;
    if (p.length > 3) {
      a = parseFloat(p[3]);
      if (p[3].indexOf('%') >= 0) a /= 100;
      if (isNaN(a)) a = 1;
    }
    var c = [parseFloat(p[0]) / 255, parseFloat(p[1]) / 255, parseFloat(p[2]) / 255, a];
    return isNaN(c[0]) || isNaN(c[1]) || isNaN(c[2]) ? null : c;
  }
  function fmt(c) {
    var r = Math.round(c[0] * 255), g = Math.round(c[1] * 255), b = Math.round(c[2] * 255);
    if (c[3] >= 1) return 'rgb(' + r + ', ' + g + ', ' + b + ')';
    return 'rgba(' + r + ', ' + g + ', ' + b + ', ' + Math.round(c[3] * 1000) / 1000 + ')';
  }
  function mapColor(role, s) {
    var c = parse(s);
    if (!c || c[3] <= 0) return null;
    var m = mapRGB(role, c[0], c[1], c[2]);
    return m ? fmt([m[0], m[1], m[2], c[3]]) : null;
  }
  /* A gradient's stops, mapped as backgrounds: [new value or null, first opaque stop]. */
  function mapGradient(s) {
    var out = '', i = 0, changed = false, first = null;
    for (;;) {
      var k = s.indexOf('rgb', i);
      if (k < 0) break;
      var e = s.indexOf(')', k);
      if (e < 0) break;
      var tok = s.slice(k, e + 1), c = parse(tok);
      out += s.slice(i, k);
      if (c) {
        var m = mapRGB(BG, c[0], c[1], c[2]), f = m ? [m[0], m[1], m[2], c[3]] : c;
        if (!first && c[3] >= 0.5) first = f;
        if (m) { changed = true; out += fmt(f); } else out += tok;
      } else {
        out += tok;
      }
      i = e + 1;
    }
    out += s.slice(i);
    return [changed ? out : null, first];
  }

  /* Nig's declarations, recorded so they can be put back. */
  function setp(el, r, k, v) {
    var st = el.style;
    if (!r.p[k]) r.p[k] = [st.getPropertyValue(k), st.getPropertyPriority(k), ''];
    st.setProperty(k, v, 'important');
    r.p[k][2] = st.getPropertyValue(k);
    touched.add(el);
  }
  function restore(el) {
    var r = rec.get(el);
    if (!r) return;
    rec.delete(el);
    touched.delete(el);
    var st = el.style;
    for (var k in r.p) {
      var o = r.p[k];
      /* A value the page set since is the page's: it stays. */
      if (st.getPropertyValue(k) !== o[2] || st.getPropertyPriority(k) !== 'important') continue;
      if (o[0]) st.setProperty(k, o[0], o[1]); else st.removeProperty(k);
    }
  }
  function entry(el) {
    var r = rec.get(el);
    if (!r) { r = {p: {}}; rec.set(el, r); }
    return r;
  }
  function sig(el) {
    var st = el.style;
    if (!st) return '';
    var s = '';
    for (var i = 0; i < SIG.length; i++) s += st.getPropertyValue(SIG[i]) + ';';
    return s;
  }

  function parentOf(el) {
    return el.parentElement || (el.parentNode && el.parentNode.host) || null;
  }
  /* What is behind an element already on the page, from what was decided
     for it or, failing that, what it shows now. */
  function liveBackdrop(el) {
    for (var e = el; e; e = parentOf(e)) {
      var r = rec.get(e);
      if (r && r.b !== undefined) return r.b;
      var cs = getComputedStyle(e), c = parse(cs.backgroundColor), bi = cs.backgroundImage;
      if (bi && bi.indexOf('url(') >= 0 && (!c || c[3] < 0.5)) return MEDIA;
      if (c && c[3] >= 0.5) return luma(c) < 0.5 ? DARK : LIGHT;
    }
    return DARK;
  }
  /* The page's own colour behind a colour inherited from Nig's. */
  function inheritedOrig(el, color) {
    for (var e = el; e; e = parentOf(e)) {
      var r = rec.get(e);
      if (r && r.co !== undefined) return r.cout === color ? r.co : color;
    }
    return color;
  }

  /* A colour transition would animate every put-back and write: it is
     held off until the written colours have been styled once. */
  function holdTransition(el, held) {
    var st = el.style;
    held.push([el, st.getPropertyValue('transition-property'), st.getPropertyPriority('transition-property')]);
    st.setProperty('transition-property', 'none', 'important');
  }
  function releaseTransitions(held) {
    if (!held.length) return;
    getComputedStyle(held[0][0]).color;  /* one style pass with no transition */
    for (var i = 0; i < held.length; i++) {
      var h = held[i], st = h[0].style;
      if (st.getPropertyValue('transition-property') !== 'none') continue;
      if (h[1]) st.setProperty('transition-property', h[1], h[2]); else st.removeProperty('transition-property');
    }
  }
  function animates(cs) {
    var d = (cs.transitionDuration || '').split(',');
    for (var i = 0; i < d.length; i++) if (parseFloat(d[i]) > 0) return cs.transitionProperty !== 'none';
    return false;
  }
  function hasDecls(r) {
    for (var k in r.p) return true;
    return false;
  }

  function watch(n) {
    if (!observer || watched.has(n)) return;
    watched.add(n);
    observer.observe(n, OPTS);
  }

  function gather(root, items, held) {
    var stack = [root];
    while (stack.length) {
      var el = stack.pop();
      if (!el || el.nodeType !== 1 || SKIP[el.tagName]) continue;
      if (el.namespaceURI === SVGNS) {
        if (el.tagName.toLowerCase() === 'svg') {
          var all = el.querySelectorAll('*');
          restore(el);
          for (var n = 0; n < all.length; n++) restore(all[n]);
          items.push({el: el, svg: true});
        }
        continue;
      }
      var had = rec.get(el), tx = !!(had && hasDecls(had));
      if (tx) holdTransition(el, held);
      restore(el);
      items.push({el: el, tx: tx});
      var sr = el.shadowRoot, i;
      if (sr) {
        watch(sr);
        for (i = sr.children.length - 1; i >= 0; i--) stack.push(sr.children[i]);
      }
      for (i = el.children.length - 1; i >= 0; i--) stack.push(el.children[i]);
    }
  }

  /* Three passes so the page is styled once: put back, read, write. */
  function run(roots) {
    var items = [], info = new Map(), held = [], i, k, n;
    for (i = 0; i < roots.length; i++) gather(roots[i], items, held);
    if (!items.length) { releaseTransitions(held); return; }
    var html = document.documentElement, body = document.body;

    for (i = 0; i < items.length; i++) {
      k = items[i];
      var el = k.el, p = parentOf(el);
      k.parent = (p && info.get(p)) || null;
      if (!k.parent) k.pb = p ? liveBackdrop(p) : DARK;
      if (k.svg) {
        var rect = el.getBoundingClientRect();
        k.small = rect.width <= 64 && rect.height <= 64;
        if (k.small) {
          k.kids = [];
          var all = [el].concat(Array.prototype.slice.call(el.querySelectorAll('*')));
          for (n = 0; n < all.length; n++) {
            var ks = getComputedStyle(all[n]);
            k.kids.push([all[n], ks.fill, ks.stroke]);
          }
        }
        continue;
      }
      var cs = getComputedStyle(el);
      k.bg = cs.backgroundColor;
      k.bi = cs.backgroundImage;
      k.color = cs.color;
      /* -webkit-text-fill-color paints the text instead of color when set. */
      var tfc = cs.getPropertyValue('-webkit-text-fill-color');
      k.tf = tfc && tfc !== k.color ? tfc : null;
      k.anim = !k.tx && animates(cs);
      k.bd = [];
      for (n = 0; n < 4; n++) {
        var side = 'border-' + SIDES[n] + '-';
        if (parseFloat(cs.getPropertyValue(side + 'width')) > 0 &&
            cs.getPropertyValue(side + 'style') !== 'none') {
          k.bd.push([side + 'color', cs.getPropertyValue(side + 'color')]);
        }
      }
      k.co = k.parent ? (k.color === k.parent.color ? k.parent.co : k.color)
                      : inheritedOrig(p, k.color);
      k.cur = k.parent && k.color === k.parent.color ? null : k.color;  /* null: inherits */
      info.set(el, k);
      if (el === html) {
        var hb = parse(k.bg), bb = body ? parse(getComputedStyle(body).backgroundColor) : null;
        k.bare = (!hb || hb[3] === 0) && (!bb || bb[3] === 0);
      }
    }

    for (i = 0; i < items.length; i++) if (items[i].anim) holdTransition(items[i].el, held);

    for (i = 0; i < items.length; i++) {
      k = items[i];
      var e2 = k.el, b = k.parent ? k.parent.b : k.pb;
      if (k.svg) {
        if (!k.small || b !== DARK) continue;
        for (n = 0; n < k.kids.length; n++) {
          var kid = k.kids[n], kr = entry(kid[0]);
          var f = mapColor(TEXT, kid[1]), s = mapColor(TEXT, kid[2]);
          if (f) setp(kid[0], kr, 'fill', f);
          if (s) setp(kid[0], kr, 'stroke', s);
          kr.sig = sig(kid[0]);
        }
        continue;
      }
      var r = entry(e2);
      if (e2 === html) {
        setp(e2, r, 'color-scheme', 'dark');
        if (k.bare) setp(e2, r, 'background-color', 'rgb(26, 26, 26)');
        b = DARK;
      }
      var bgc = parse(k.bg);
      if (bgc && bgc[3] > 0) {
        var m = mapRGB(BG, bgc[0], bgc[1], bgc[2]), fc = m ? [m[0], m[1], m[2], bgc[3]] : bgc;
        if (m) setp(e2, r, 'background-color', fmt(fc));
        if (bgc[3] >= 0.5) b = luma(fc) < 0.5 ? DARK : LIGHT;
      }
      if (k.bi && k.bi !== 'none') {
        if (k.bi.indexOf('url(') >= 0) {
          if (!bgc || bgc[3] < 0.5) b = MEDIA;
        } else if (k.bi.indexOf('gradient(') >= 0) {
          var gr = mapGradient(k.bi);
          if (gr[0]) setp(e2, r, 'background-image', gr[0]);
          if (gr[1]) b = luma(gr[1]) < 0.5 ? DARK : LIGHT;
        }
      }
      k.b = r.b = b;
      for (n = 0; n < k.bd.length; n++) {
        var bc = mapColor(BORDER, k.bd[n][1]);
        if (bc) setp(e2, r, k.bd[n][0], bc);
      }
      /* Text: lightened on a dark backdrop, the page's own elsewhere. A
         colour equal to the parent's may be inherited or the element's own
         rule (body and a component both saying #333): it is left unwritten
         only when it comes out right either way. */
      var want = b === DARK ? (mapColor(TEXT, k.co) || k.co) : k.co;
      if (want !== k.color || (k.cur === null && want !== k.parent.out)) setp(e2, r, 'color', want);
      if (k.tf) {
        var tf = b === DARK ? mapColor(TEXT, k.tf) : null;
        if (tf) setp(e2, r, '-webkit-text-fill-color', tf);
      }
      k.out = want;
      r.co = k.co;
      r.cout = want;
    }
    releaseTransitions(held);
    for (i = 0; i < items.length; i++) {
      if (!items[i].svg) entry(items[i].el).sig = sig(items[i].el);
    }
  }

  function covered(n) {
    for (var a = parentOf(n); a; a = parentOf(a)) if (pending.has(a)) return true;
    return false;
  }
  function flush() {
    scheduled = false;
    if (!active) { pending.clear(); full = false; return; }
    var roots = [];
    if (full) {
      full = false;
      if (document.documentElement) roots.push(document.documentElement);
    } else {
      pending.forEach(function (n) { if (n.isConnected && !covered(n)) roots.push(n); });
    }
    pending.clear();
    if (touched.size > 4000) touched.forEach(function (el) { if (!el.isConnected) touched.delete(el); });
    if (roots.length) run(roots);
    if (observer) observer.takeRecords();  /* Nig's own writes */
  }
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    if (G.requestAnimationFrame) G.requestAnimationFrame(flush); else setTimeout(flush, 16);
  }
  function repass() { if (active) { full = true; schedule(); } }

  function onMutations(list) {
    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      if (m.type === 'childList') {
        if (m.target.nodeName === 'STYLE') { full = true; continue; }  /* its rules changed */
        for (var j = 0; j < m.addedNodes.length; j++) {
          var a = m.addedNodes[j];
          if (a.nodeType !== 1) continue;
          if (a.tagName === 'STYLE' || a.tagName === 'LINK') full = true;  /* a link: again once loaded */
          else pending.add(a);
        }
      } else {
        var t = m.target;
        if (m.attributeName === 'style') {
          var r = rec.get(t);
          if (r && r.sig === sig(t)) continue;  /* a transform, a size: no colour */
        }
        pending.add(t);
      }
    }
    if (pending.size || full) schedule();
  }

  function start() {
    watched = new WeakSet();
    observer = new MutationObserver(onMutations);
    observer.observe(document, OPTS);
    full = true;
    flush();
  }
  function stop() {
    if (observer) { observer.disconnect(); observer = null; }
    pending.clear();
    full = false;
    touched.forEach(function (el) { restore(el); });
    touched.clear();
  }

  /* Style sheets that arrive later change computed colours without a mutation. */
  document.addEventListener('DOMContentLoaded', repass);
  G.addEventListener('load', repass);
  document.addEventListener('load', function (e) {
    if (e.target && e.target.tagName === 'LINK') repass();
  }, true);

  G.__nigWeb = {
    set: function (on) {
      on = !!on;
      if (on === active) { repass(); return; }
      active = on;
      if (on) start(); else stop();
    },
    mapRGB: mapRGB,
    mapColor: mapColor,
    mapGradient: mapGradient
  };
})();
