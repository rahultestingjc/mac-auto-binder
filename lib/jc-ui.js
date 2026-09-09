// =====================================================================
// jc-ui.js - native AppKit UI for JumpCloud enrollment (zero deps).
//
// Runs via `osascript -l JavaScript`, present on every macOS. Renders the
// same card design as the Windows WPF client: rounded white card, brand
// accent, typography scale, numbered "what happens next" steps, native
// spinner. No swiftDialog, no third-party binary, no ugly fallback.
//
// TWO MODES
//
//   one-shot :  argv[0] = a JSON screen spec.
//               stdout  = {"button":0|1,"fields":{...}}
//               exit    = 0 button1, 1 button2, 2 dismissed.
//               Handy for previewing a single screen.
//
//   server   :  argv[0] = "--server". Reads one JSON screen spec per line
//               on stdin and writes one JSON result per line on stdout,
//               reusing ONE window for the whole flow: the content view is
//               swapped and the window resized with its top edge pinned, so
//               the card appears to change in place instead of a new window
//               appearing for every step. {"quit":true} ends the session.
//
//               A spec with "screen":"progress" also takes "until":<path>
//               and stays up, spinner running, until that file appears -
//               that is how the caller shows progress while it works.
//               Its result is {"button":-3}.
//
// SPEC keys: screen, company, accent, title, message, error, note,
//            reference, support, footer, steps[], back, until,
//            fields[{key,label,secure,value,placeholder}],
//            button1, button2,
//            icon ("link"|"lock"|"warn"|"error"|"info"|"check")
//
// JXA CONSTRAINTS - the bridge is narrower than plain AppKit. These crash
// or silently no-op, so none of them appear below:
//   1. $.NSApp is nil until NSApplication.sharedApplication is sent.
//      Without it setActivationPolicy does nothing and, worse,
//      runModalForWindow returns nil - the window flashes and every
//      screen reports "dismissed".
//   2. Assigning a CGColorRef (layer.backgroundColor / layer.borderColor)
//      kills the process with SIGKILL. All fills, borders and corner
//      radii therefore go through NSBox, which takes NSColor.
//   3. NSAttributedString's initialisers are not exposed, so there are no
//      attributed titles. Buttons are an NSBox + a plain NSTextField with
//      a transparent, title-less NSButton laid over the top: the button
//      draws nothing and takes every click, the label underneath shows
//      through with the exact font and colour we want.
//   4. Inside an ObjC.registerSubclass implementation, `id` arguments come
//      back with a lighter wrapper - sender.tag is a STRING. Coerce it.
// =====================================================================
ObjC.import('Cocoa');
ObjC.import('stdlib');

function run(argv) {
  var SERVER = (argv || []).length > 0 && argv[0] === '--server';

  // NSApp must exist before anything touches it (see constraint 1).
  $.NSApplication.sharedApplication;

  // Accent is per-spec, so these are set by setAccent() before each build.
  var ACCENT, ACCENT_DARK, ICON_TINT, STEP_TINT, HEADER_TINT;
  // ---------- palette (sampled from docs/windows-reference) ----------
  var WIN_BG       = '#F5F6F8';
  var CARD_BG      = '#FFFFFF';
  var CARD_BORDER  = '#E8EAED';
  var TITLE_C      = '#14203A';
  var BODY_C       = '#5D6876';
  var LABEL_C      = '#475364';
  var MUTED_C      = '#A9B0BF';
  var FIELD_BG     = '#FFFFFF';
  var FIELD_BORDER = '#DADDE2';
  var BTN2_BORDER  = '#DADDE2';
  var BTN2_TEXT    = '#2E3947';
  var STEP_BG      = '#F8F9FA';
  var STEP_BORDER  = '#EAECEF';
  var ERROR_C      = '#C3361E';

  // ---------- colour helpers ----------
  function hexColor(hex, alpha) {
    hex = (hex || '#000000').replace('#', '');
    var r = parseInt(hex.substr(0, 2), 16) / 255,
        g = parseInt(hex.substr(2, 2), 16) / 255,
        b = parseInt(hex.substr(4, 2), 16) / 255;
    return $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, alpha === undefined ? 1.0 : alpha);
  }
  function chan(hex) {
    hex = hex.replace('#', '');
    return [0, 2, 4].map(function (i) { return parseInt(hex.substr(i, 2), 16); });
  }
  function toHex(c) {
    return '#' + c.map(function (v) {
      v = Math.max(0, Math.min(255, Math.round(v)));
      return ('0' + v.toString(16)).slice(-2);
    }).join('');
  }
  function shade(hex, factor) {            // <1 darkens
    return toHex(chan(hex).map(function (v) { return v * factor; }));
  }
  function tint(hex, white) {              // white = fraction of white mixed in
    return toHex(chan(hex).map(function (v) { return 255 * white + v * (1 - white); }));
  }
  function setAccent(a) {
    ACCENT      = a || '#0E8A5F';
    ACCENT_DARK = shade(ACCENT, 0.88);   // glyphs, step numbers, links
    ICON_TINT   = tint(ACCENT, 0.92);    // large icon circle
    STEP_TINT   = tint(ACCENT, 0.87);    // numbered step badges
    HEADER_TINT = tint(ACCENT, 0.75);    // small header lock badge
  }
  setAccent(null);

  // NSTextAlignment: BridgeSupport still reports the legacy ordering
  // (left,right,center) under these names, while AppKit at runtime uses the
  // UIKit ordering, so the bridge constant for "center" right-aligns. Literals.
  var ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2;

  // ---------- view helpers ----------
  function label(text, size, weight, colorHex, width, align) {
    var f = $.NSTextField.alloc.initWithFrame($.NSMakeRect(0, 0, width, 20));
    f.stringValue = text || '';
    f.font = $.NSFont.systemFontOfSizeWeight(size, weight);
    f.textColor = hexColor(colorHex);
    f.bezeled = false;
    f.drawsBackground = false;
    f.editable = false;
    f.selectable = false;
    f.focusRingType = $.NSFocusRingTypeNone;
    f.usesSingleLineMode = false;
    f.lineBreakMode = $.NSLineBreakByWordWrapping;
    f.cell.wraps = true;
    f.cell.scrollable = false;
    f.alignment = (align === undefined) ? ALIGN_LEFT : align;
    f.preferredMaxLayoutWidth = width;
    var h = f.fittingSize.height;
    f.frame = $.NSMakeRect(0, 0, width, h);
    return f;
  }

  // Rounded, filled, optionally bordered container. NSBox is the only
  // route to a corner radius that does not require a CGColor.
  function box(w, h, fillHex, radius, borderHex) {
    var b = $.NSBox.alloc.initWithFrame($.NSMakeRect(0, 0, w, h));
    b.boxType = $.NSBoxCustom;
    b.titlePosition = $.NSNoTitle;
    b.contentViewMargins = $.NSMakeSize(0, 0);
    b.fillColor = hexColor(fillHex);
    b.cornerRadius = radius;
    if (borderHex) {
      b.borderWidth = 1;
      b.borderColor = hexColor(borderHex);
    } else {
      b.borderWidth = 0;
      b.borderColor = $.NSColor.clearColor;
    }
    return b;
  }

  // Transparent, title-less button laid over a label (see constraint 3).
  function hitButton(w, h, tag) {
    var b = $.NSButton.alloc.initWithFrame($.NSMakeRect(0, 0, w, h));
    b.title = '';
    b.bordered = false;
    b.focusRingType = $.NSFocusRingTypeNone;
    b.tag = tag;
    return b;
  }

  function flatButton(title, w, primary, tag) {
    var H = 44;
    var v = box(w, H, primary ? ACCENT : '#FFFFFF', 8, primary ? null : BTN2_BORDER);
    var lab = label(title, 14, primary ? $.NSFontWeightSemibold : $.NSFontWeightMedium,
                    primary ? '#FFFFFF' : BTN2_TEXT, w, ALIGN_CENTER);
    lab.frame = $.NSMakeRect(0, (H - lab.frame.size.height) / 2, w, lab.frame.size.height);
    v.addSubview(lab);
    var b = hitButton(w, H, tag);
    v.addSubview(b);
    return { view: v, button: b };
  }

  function linkButton(text, w, size, colorHex, align, tag) {
    var H = 20;
    var v = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, w, H));
    var lab = label(text, size, $.NSFontWeightMedium, colorHex, w, align);
    lab.frame = $.NSMakeRect(0, (H - lab.frame.size.height) / 2, w, lab.frame.size.height);
    v.addSubview(lab);
    var b = hitButton(w, H, tag);
    v.addSubview(b);
    return { view: v, button: b, label: lab };
  }

  // SF Symbol, tinted. Falls back to a text glyph on macOS < 11.
  var ICONS = {
    link:  { bg: ICON_TINT,  fg: ACCENT_DARK, sym: 'link',                     glyph: '⚭' },
    lock:  { bg: ICON_TINT,  fg: ACCENT_DARK, sym: 'lock.fill',                glyph: '●' },
    check: { bg: '#10A35A',  fg: '#FFFFFF',   sym: 'checkmark',                glyph: '✓' },
    warn:  { bg: '#FEF5D1',  fg: '#B45309',   sym: 'exclamationmark.triangle', glyph: '!' },
    error: { bg: '#FFE8E6',  fg: '#C3361E',   sym: 'exclamationmark.circle',   glyph: '!' },
    info:  { bg: '#EAECEE',  fg: '#475364',   sym: 'info.circle',              glyph: 'i' }
  };
  var SYMBOL_SCALE_MEDIUM = 2;   // NSImageSymbolScaleMedium: not exposed by the bridge
  function symbolImage(name, pointSize, weight) {
    try {
      var img = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription($(name), $());
      if (!img || img.isNil()) { return null; }
      var cfg = $.NSImageSymbolConfiguration.configurationWithPointSizeWeightScale(
        pointSize, weight, SYMBOL_SCALE_MEDIUM);
      var out = img.imageWithSymbolConfiguration(cfg);
      return (out && !out.isNil()) ? out : img;
    } catch (e) { return null; }
  }
  function iconBadge(kind, size, radius, symScale, fillHex) {
    var m = ICONS[kind] || ICONS.lock;
    var v = box(size, size, fillHex || m.bg, radius === undefined ? size / 2 : radius, null);
    var img = symbolImage(m.sym, size * (symScale || 0.42), $.NSFontWeightMedium);
    if (img) {
      var iv = $.NSImageView.alloc.initWithFrame($.NSMakeRect(0, 0, size, size));
      iv.image = img;
      iv.imageScaling = $.NSImageScaleNone;   // natural symbol size, centred
      try { iv.contentTintColor = hexColor(m.fg); } catch (e) {}
      v.addSubview(iv);
    } else {
      var t = label(m.glyph, size * 0.44, $.NSFontWeightBold, m.fg, size, ALIGN_CENTER);
      t.frame = $.NSMakeRect(0, (size - t.frame.size.height) / 2, size, t.frame.size.height);
      v.addSubview(t);
    }
    return v;
  }

  function textInput(secure, w, h, tag) {
    var t = (secure ? $.NSSecureTextField : $.NSTextField)
              .alloc.initWithFrame($.NSMakeRect(14, (h - 22) / 2, w - 28, 22));
    t.font = $.NSFont.systemFontOfSize(14);
    t.textColor = hexColor('#14203A');
    t.bezeled = false;
    t.drawsBackground = false;
    t.focusRingType = $.NSFocusRingTypeNone;
    t.usesSingleLineMode = true;
    t.tag = tag;
    return t;
  }


  // ---------- layout constants ----------
  var CARD_W = 440, PAD = 34, CONTENT_W = CARD_W - PAD * 2, MARGIN = 22;

  // Per-screen state the shared handler needs. Rebuilt by buildPage().
  var cur = null;

  // buildPage(spec) -> { card, winW, winH }. Builds one screen's card and
  // records its controls in `cur`; it never touches the window.
  function buildPage(SPEC) {
    setAccent(SPEC.accent);
    var IS_PROGRESS = SPEC.screen === 'progress';
    cur = { fieldGetters: {}, toggles: [], fieldBoxes: {}, editables: [],
            focusTarget: null, btn1: null, btn2: null, backLink: null,
            spinner: null, finished: false, isProgress: IS_PROGRESS };
    var stack = [];
    function push(view, gapAfter) {
      stack.push({ view: view, h: view.frame.size.height, gap: gapAfter || 0 });
    }
  
    // Header: lock badge + "JumpCloud" + right-aligned company.
    var header = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, CONTENT_W, 34));
    var hb = iconBadge('lock', 32, 10, 0.44, HEADER_TINT);
    hb.frame = $.NSMakeRect(0, 1, 32, 32);
    header.addSubview(hb);
    var hName = label('JumpCloud', 15, $.NSFontWeightSemibold, TITLE_C, 130);
    hName.frame = $.NSMakeRect(42, (34 - hName.frame.size.height) / 2, 130, hName.frame.size.height);
    header.addSubview(hName);
    if (SPEC.company) {
      var cw = CONTENT_W - 180;
      var hCo = label(SPEC.company, 11.5, $.NSFontWeightRegular, MUTED_C, cw, ALIGN_RIGHT);
      hCo.frame = $.NSMakeRect(180, (34 - hCo.frame.size.height) / 2, cw, hCo.frame.size.height);
      header.addSubview(hCo);
    }
    push(header, 22);
  
    // "<- Back" link (credential screen, Windows parity). Reports button 1.
    var backLink = null;
    if (SPEC.back) {
      backLink = linkButton('←  Back', 120, 13, ACCENT_DARK, ALIGN_LEFT, 101);
      push(backLink.view, 12);
    }
  
    var spinner = null;
    if (IS_PROGRESS) {
      var sHolder = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, CONTENT_W, 40));
      spinner = $.NSProgressIndicator.alloc.initWithFrame($.NSMakeRect((CONTENT_W - 32) / 2, 4, 32, 32));
      spinner.style = $.NSProgressIndicatorStyleSpinning;
      spinner.indeterminate = true;
      sHolder.addSubview(spinner);
      push(sHolder, 20);
    } else if (SPEC.icon) {
      push(iconBadge(SPEC.icon, 60), 18);
    }
  
    var textAlign = IS_PROGRESS ? ALIGN_CENTER : ALIGN_LEFT;
    if (SPEC.title)   { push(label(SPEC.title, 21, $.NSFontWeightSemibold, TITLE_C, CONTENT_W, textAlign), 10); }
    if (SPEC.message) { push(label(SPEC.message, 13, $.NSFontWeightRegular, BODY_C, CONTENT_W, textAlign), 18); }
  
    // ---------- fields ----------
    var fieldGetters = {};
    var toggles = [];
    var fieldBoxes = {};       // text-field tag -> containing NSBox (focus ring)
    var editables = [];        // every NSTextField that takes a delegate
    var focusTarget = null;
    var tagSeq = 300;
    (SPEC.fields || []).forEach(function (spec) {
      push(label(spec.label, 12.5, $.NSFontWeightSemibold, LABEL_C, CONTENT_W), 7);
  
      var H = 46;
      var boxW = spec.secure ? CONTENT_W - 58 : CONTENT_W;
      var row = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, CONTENT_W, H));
      var fb = box(boxW, H, FIELD_BG, 8, FIELD_BORDER);
      row.addSubview(fb);
  
      if (spec.secure) {
        // Secure + plain field stacked; the "Show" link swaps which is
        // visible, mirroring the Windows show/hide password control.
        var secTag = tagSeq++, plainTag = tagSeq++;
        var sec = textInput(true, boxW, H, secTag);
        var plain = textInput(false, boxW, H, plainTag);
        sec.stringValue = spec.value || '';
        if (spec.placeholder) { sec.placeholderString = spec.placeholder; plain.placeholderString = spec.placeholder; }
        plain.hidden = true;
        fb.addSubview(sec);
        fb.addSubview(plain);
        fieldBoxes[secTag] = fb;
        fieldBoxes[plainTag] = fb;
        editables.push(sec); editables.push(plain);
  
        var link = linkButton('Show', 50, 12.5, ACCENT_DARK, ALIGN_RIGHT, 200 + toggles.length);
        link.view.frame = $.NSMakeRect(CONTENT_W - 50, (H - 20) / 2, 50, 20);
        row.addSubview(link.view);
        toggles.push({ sec: sec, plain: plain, link: link, revealed: false });
  
        fieldGetters[spec.key] = (function (s2, p2) {
          return function () { return ObjC.unwrap((p2.hidden ? s2 : p2).stringValue) || ''; };
        })(sec, plain);
        if (!focusTarget || !(spec.value || '')) { focusTarget = focusTarget || sec; }
      } else {
        var tfTag = tagSeq++;
        var tf = textInput(false, boxW, H, tfTag);
        tf.stringValue = spec.value || '';
        if (spec.placeholder) { tf.placeholderString = spec.placeholder; }
        fb.addSubview(tf);
        fieldBoxes[tfTag] = fb;
        editables.push(tf);
        fieldGetters[spec.key] = (function (b) {
          return function () { return ObjC.unwrap(b.stringValue) || ''; };
        })(tf);
        if (!focusTarget && !(spec.value || '')) { focusTarget = tf; }
      }
      push(row, 16);
    });
    // Prefilled email -> land on the password, like the Windows client.
    if (!focusTarget && toggles.length) { focusTarget = toggles[0].sec; }
  
    // Inline validation / error message, as on the Windows client.
    if (SPEC.error) {
      push(label(SPEC.error, 12.5, $.NSFontWeightRegular, ERROR_C, CONTENT_W), 14);
    }
  
    // ---------- numbered "What happens next" card ----------
    if (SPEC.steps && SPEC.steps.length) {
      var inner = 18, rowGap = 12, badge = 22, gutter = 12;
      var textW = CONTENT_W - inner * 2 - badge - gutter;
      var rows = SPEC.steps.map(function (s) {
        var txt = label(s, 13, $.NSFontWeightRegular, LABEL_C, textW);
        return { txt: txt, h: Math.max(badge, txt.frame.size.height) };
      });
      var titleLab = label('What happens next', 13, $.NSFontWeightSemibold, TITLE_C, CONTENT_W - inner * 2);
      var total = inner * 2 + titleLab.frame.size.height + 12 +
                  rows.reduce(function (a, r) { return a + r.h; }, 0) + rowGap * (rows.length - 1);
      var stepCard = box(CONTENT_W, total, STEP_BG, 10, STEP_BORDER);
      var cy = total - inner - titleLab.frame.size.height;
      titleLab.frame = $.NSMakeRect(inner, cy, CONTENT_W - inner * 2, titleLab.frame.size.height);
      stepCard.addSubview(titleLab);
      cy -= 12;
      rows.forEach(function (r, i) {
        cy -= r.h;
        var bg = box(badge, badge, STEP_TINT, badge / 2, null);
        bg.frame = $.NSMakeRect(inner, cy + r.h - badge, badge, badge);
        var num = label(String(i + 1), 11, $.NSFontWeightSemibold, ACCENT_DARK, badge, ALIGN_CENTER);
        num.frame = $.NSMakeRect(0, (badge - num.frame.size.height) / 2, badge, num.frame.size.height);
        bg.addSubview(num);
        stepCard.addSubview(bg);
        r.txt.frame = $.NSMakeRect(inner + badge + gutter, cy + r.h - r.txt.frame.size.height,
                                   textW, r.txt.frame.size.height);
        stepCard.addSubview(r.txt);
        cy -= rowGap;
      });
      push(stepCard, 18);
    }
  
    if (SPEC.footer) { push(label(SPEC.footer, 13, $.NSFontWeightRegular, BODY_C, CONTENT_W), 18); }
  
    // Support reference sits directly above the buttons, as on Windows.
    if (SPEC.reference) { push(label(SPEC.reference, 11.5, $.NSFontWeightRegular, MUTED_C, CONTENT_W), 16); }
  
    // ---------- buttons + fine print ----------
    var btn1 = null, btn2 = null;
    var tailGap = (SPEC.note || SPEC.support) ? 16 : 0;
    if (SPEC.button1) { btn1 = flatButton(SPEC.button1, CONTENT_W, true, 100); push(btn1.view, SPEC.button2 ? 10 : tailGap); }
    if (SPEC.button2) { btn2 = flatButton(SPEC.button2, CONTENT_W, false, 101); push(btn2.view, tailGap); }
    if (SPEC.note)    { push(label(SPEC.note, 11.5, $.NSFontWeightRegular, MUTED_C, CONTENT_W), SPEC.support ? 12 : 0); }
    if (SPEC.support) { push(label(SPEC.support, 11.5, $.NSFontWeightRegular, MUTED_C, CONTENT_W), 0); }
  
    // ---------- measure the card ----------
    var contentH = stack.reduce(function (a, s) { return a + s.h + s.gap; }, 0);
    var CARD_H = contentH + PAD * 2;
    var WIN_W = CARD_W + MARGIN * 2, WIN_H = CARD_H + MARGIN * 2;
    var card = box(CARD_W, CARD_H, CARD_BG, 12, CARD_BORDER);
    card.frame = $.NSMakeRect(MARGIN, MARGIN, CARD_W, CARD_H);
    var shadow = $.NSShadow.alloc.init;
    shadow.shadowBlurRadius = 16;
    shadow.shadowOffset = $.NSMakeSize(0, -2);
    shadow.shadowColor = $.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.10);
    card.shadow = shadow;

    var y = CARD_H - PAD;
    stack.forEach(function (s) {
      y -= s.h;
      s.view.frame = $.NSMakeRect(PAD, y, s.view.frame.size.width, s.h);
      card.addSubview(s.view);
      y -= s.gap;
    });

    cur.fieldGetters = fieldGetters;
    cur.toggles      = toggles;
    cur.fieldBoxes   = fieldBoxes;
    cur.editables    = editables;
    cur.focusTarget  = focusTarget;
    cur.btn1         = btn1;
    cur.btn2         = btn2;
    cur.backLink     = backLink;
    cur.spinner      = spinner;
    return { card: card, winW: WIN_W, winH: WIN_H };
  }
  // ---------- the one window, created once and reused ----------
  var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, CARD_W + MARGIN * 2, 400),
    $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable,
    $.NSBackingStoreBuffered, false);
  win.title = 'JumpCloud Account Setup';
  win.backgroundColor = hexColor(WIN_BG);
  win.titlebarAppearsTransparent = true;
  // Programmatic NSWindows are released on close by default; keep it alive so
  // field values can still be read after the modal ends, and so the same
  // window can be shown again for the next screen.
  win.releasedWhenClosed = false;
  // Title-bar height, measured once, so a resize can keep the TOP edge pinned.
  var CHROME_H = win.frame.size.height - win.contentView.frame.size.height;
  var placed = false;
  var untilPath = '';

  // Resize around a fixed TOP edge: the title bar stays put and only the
  // bottom moves, so the card reads as one panel changing rather than a new
  // window appearing in a different place.
  function applyGeometry(winW, winH) {
    var frameH = winH + CHROME_H, vf = null, x, top;
    try { vf = $.NSScreen.mainScreen.visibleFrame; } catch (e) { vf = null; }
    if (placed) {
      x = win.frame.origin.x;
      top = win.frame.origin.y + win.frame.size.height;
    } else if (vf) {
      x = Math.round(vf.origin.x + (vf.size.width - winW) / 2);
      top = vf.origin.y + vf.size.height - Math.round(vf.size.height * 0.14);
    } else {
      x = 0; top = frameH;
    }
    var oy = top - frameH;
    if (vf && oy < vf.origin.y + 10) { oy = vf.origin.y + 10; }
    win.setFrameDisplayAnimate($.NSMakeRect(x, oy, winW, frameH), true, placed);
    placed = true;
  }

  // ---------- actions (one handler for the life of the process) ----------
  function stop(code) {
    if (!cur || cur.finished) { return; }
    cur.finished = true;
    $.NSApp.stopModalWithCode(code);
  }
  function setFocusRing(tag, on) {
    if (!cur) { return; }
    var fb = cur.fieldBoxes[tag];
    if (!fb) { return; }
    fb.borderColor = hexColor(on ? ACCENT : FIELD_BORDER);
    fb.borderWidth = on ? 2 : 1;
  }

  ObjC.registerSubclass({
    name: 'JCHandler',
    superclass: 'NSObject',
    methods: {
      'clicked:': {
        types: ['void', ['id']],
        // Inside a registerSubclass implementation JXA hands 'id' arguments
        // back with a lighter wrapper: sender.tag arrives as a STRING, so a
        // strict compare against 100 never matches. Coerce every tag.
        implementation: function (sender) { stop(Number(sender.tag) === 100 ? 0 : 1); }
      },
      'toggled:': {
        types: ['void', ['id']],
        implementation: function (sender) {
          var t = cur.toggles[Number(sender.tag) - 200];
          if (!t) { return; }
          if (!t.revealed) {
            t.plain.stringValue = t.sec.stringValue;
            t.sec.hidden = true;
            t.plain.hidden = false;
            t.link.label.stringValue = 'Hide';
            t.revealed = true;
            win.makeFirstResponder(t.plain);
          } else {
            t.sec.stringValue = t.plain.stringValue;
            t.plain.hidden = true;
            t.sec.hidden = false;
            t.link.label.stringValue = 'Show';
            t.revealed = false;
            win.makeFirstResponder(t.sec);
          }
        }
      },
      'controlTextDidBeginEditing:': {
        types: ['void', ['id']],
        implementation: function (note) { setFocusRing(Number(note.object.tag), true); }
      },
      'controlTextDidEndEditing:': {
        types: ['void', ['id']],
        implementation: function (note) { setFocusRing(Number(note.object.tag), false); }
      },
      // Progress screens stay up until the caller drops a signal file. The
      // timer is added to the MODAL run-loop mode, or it would never fire.
      'tick:': {
        types: ['void', ['id']],
        implementation: function (t) {
          if (untilPath && $.NSFileManager.defaultManager.fileExistsAtPath($(untilPath))) {
            stop(3);
          }
        }
      },
      'windowWillClose:': {
        types: ['void', ['id']],
        implementation: function (note) { stop(-1); }
      }
    }
  });
  var handler = $.JCHandler.alloc.init;
  win.delegate = handler;

  // ---------- show one screen, return its result ----------
  function showScreen(SPEC) {
    var page = buildPage(SPEC);
    var host = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, page.winW, page.winH));
    host.addSubview(page.card);
    win.contentView = host;
    applyGeometry(page.winW, page.winH);

    if (cur.btn1) {
      cur.btn1.button.target = handler; cur.btn1.button.action = 'clicked:';
      cur.btn1.button.keyEquivalent = '\r';
    }
    if (cur.btn2)     { cur.btn2.button.target = handler;     cur.btn2.button.action = 'clicked:'; }
    if (cur.backLink) { cur.backLink.button.target = handler; cur.backLink.button.action = 'clicked:'; }
    cur.toggles.forEach(function (t) { t.link.button.target = handler; t.link.button.action = 'toggled:'; });
    cur.editables.forEach(function (tf) { tf.delegate = handler; });

    win.makeKeyAndOrderFront(null);
    if (cur.focusTarget) {
      win.makeFirstResponder(cur.focusTarget);
      setFocusRing(Number(cur.focusTarget.tag), true);
    }
    if (cur.spinner) { cur.spinner.startAnimation(null); }
    $.NSApp.activateIgnoringOtherApps(true);

    var timer = null;
    untilPath = (cur.isProgress && SPEC.until) ? String(SPEC.until) : '';
    if (untilPath) {
      timer = $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
        0.15, handler, 'tick:', $(), true);
      $.NSRunLoop.currentRunLoop.addTimerForMode(timer, $.NSModalPanelRunLoopMode);
    }

    var code = Number($.NSApp.runModalForWindow(win));
    if (timer) { timer.invalidate; }
    cur.finished = true;

    var btn = (code === 0 || code === 1) ? code : (code === 3 ? -3 : -1);
    var result = { button: btn, fields: {} };
    Object.keys(cur.fieldGetters).forEach(function (k) {
      result.fields[k] = cur.fieldGetters[k]();
    });
    return result;
  }

  // ---------- I/O ----------
  var stdinFH = $.NSFileHandle.fileHandleWithStandardInput;
  var inBuf = '';
  function readLine() {
    while (inBuf.indexOf('\n') < 0) {
      var d = stdinFH.availableData;
      if (!d || d.length === 0) { return null; }        // EOF: caller went away
      inBuf += ObjC.unwrap(
        $.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding));
    }
    var i = inBuf.indexOf('\n');
    var line = inBuf.substr(0, i);
    inBuf = inBuf.substr(i + 1);
    return line;
  }
  function writeLine(s) {
    $.NSFileHandle.fileHandleWithStandardOutput.writeData(
      $.NSString.alloc.initWithUTF8String(s + '\n')
        .dataUsingEncoding($.NSUTF8StringEncoding));
  }

  $.NSApp.setActivationPolicy($.NSApplicationActivationPolicyRegular);

  if (SERVER) {
    var line;
    while ((line = readLine()) !== null) {
      if (!line) { continue; }
      var spec;
      try { spec = JSON.parse(line); }
      catch (e) { writeLine('{"button":-2,"fields":{}}'); continue; }
      if (spec.quit) { break; }
      writeLine(JSON.stringify(showScreen(spec)));
    }
    win.orderOut(null);
    $.exit(0);
  }

  // One-shot: exactly the old contract, so previews and existing callers work.
  var result = showScreen(JSON.parse(argv[0] || '{}'));
  win.orderOut(null);
  writeLine(JSON.stringify(result));
  $.exit(result.button < 0 ? 2 : result.button);
}
