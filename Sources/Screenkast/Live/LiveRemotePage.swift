import Foundation

/// The web page of the remote control (served by Erklärbär itself, no internet needed).
enum LiveRemotePage {
    static let manifest = #"""
    {"name":"Erklärbär Live","short_name":"Erklärbär","display":"standalone","background_color":"#15151b","theme_color":"#15151b",
     "icons":[{"src":"/icon.png","sizes":"180x180","type":"image/png"}]}
    """#

    static let html = #"""
    <!doctype html>
    <html lang="de">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Erklärbär">
    <meta name="theme-color" content="#15151b">
    <link rel="apple-touch-icon" href="/icon.png">
    <link rel="manifest" href="/manifest.webmanifest">
    <title>Erklärbär Live</title>
    <style>
    :root{--bg:#15151b;--panel:#1f1f28;--panel2:#272732;--line:rgba(255,255,255,.09);--text:#f3f3f8;--dim:#9b9bab;
      --brand:#6a4ce0;--brand2:#8d70ff;--rec:#ff3b3b;--ok:#34c759;--warn:#ff9f0a;--focus:#ffd60a;--r:14px}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    html,body{margin:0;background:var(--bg);color:var(--text);font:16px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
      -webkit-user-select:none;user-select:none;-webkit-text-size-adjust:100%}
    body{padding:max(12px,env(safe-area-inset-top)) max(12px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(12px,env(safe-area-inset-left))}
    button,select{font:inherit;color:inherit;touch-action:manipulation;cursor:pointer}
    select,input{-webkit-user-select:auto;user-select:auto}
    button{border:0;background:none}
    .hidden{display:none!important}
    /* Pairing */
    #pair{min-height:85vh;display:flex;align-items:center;justify-content:center}
    .card{background:var(--panel);border:1px solid var(--line);border-radius:22px;padding:28px 24px;max-width:420px;text-align:center}
    .card img{width:76px;height:76px;border-radius:18px}
    .card h1{font-size:22px;margin:14px 0 6px}
    .card p{color:var(--dim);margin:6px 0 0}
    .spin{width:26px;height:26px;margin:18px auto 0;border:3px solid var(--line);border-top-color:var(--brand2);border-radius:50%;animation:spin 1s linear infinite}
    @keyframes spin{to{transform:rotate(360deg)}}
    /* Header */
    header{display:flex;align-items:center;gap:10px;margin-bottom:12px}
    header .title{font-weight:700;font-size:18px;display:flex;align-items:center;gap:8px;white-space:nowrap}
    .dot{width:10px;height:10px;border-radius:50%;background:var(--rec);box-shadow:0 0 0 3px rgba(255,59,59,.18)}
    .dot.off{background:#666;box-shadow:none}
    .chips{display:flex;gap:6px;margin-left:auto;flex-wrap:wrap;justify-content:flex-end}
    .chip{font-size:13px;color:var(--dim);background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:3px 10px;white-space:nowrap}
    .chip.rec{color:#fff;background:var(--rec);border-color:var(--rec)}
    .chip.warn{color:var(--warn)}
    /* Layout */
    .grid{display:grid;gap:14px}
    @media (min-width:820px){.grid{grid-template-columns:minmax(0,1.15fr) minmax(0,1fr);align-items:start}.stage{position:sticky;top:12px}}
    .box{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:12px}
    .pv{position:relative;width:100%;aspect-ratio:16/9;border-radius:12px;overflow:hidden;background:#000}
    .preview{width:100%;height:100%;display:block;object-fit:contain}
    .bubble{position:absolute;aspect-ratio:1;border-radius:50%;border:2px solid var(--focus);transform:translate(-50%,-50%);touch-action:none;cursor:grab;
      box-shadow:0 0 0 1px rgba(0,0,0,.4)}
    .bubble.drag{border-width:3px;background:rgba(255,214,10,.12)}
    .notice{margin-top:10px;padding:10px 12px;border-radius:11px;background:rgba(255,159,10,.15);color:var(--warn);font-size:14px;display:flex;gap:10px;align-items:center}
    .notice span{flex:1}
    .small{min-height:34px;padding:0 12px;border-radius:9px;background:var(--panel2);border:1px solid var(--line);font-size:14px;font-weight:600;color:var(--text);white-space:nowrap}
    .row{display:flex;gap:10px;margin-top:10px}
    .big{flex:1;min-height:58px;border-radius:var(--r);background:var(--panel2);border:1px solid var(--line);display:flex;align-items:center;justify-content:center;gap:10px;font-weight:600;font-size:17px;white-space:nowrap}
    .big svg{width:24px;height:24px;flex:none}
    .big.muted,.big.recording{background:var(--rec);border-color:var(--rec);color:#fff}
    .scenes{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:10px}
    .scene{min-height:64px;border-radius:12px;background:var(--panel2);border:1.5px solid var(--line);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;font-size:14px;font-weight:600;padding:4px}
    .scene svg{width:24px;height:24px;opacity:.9}
    .scene.on{border-color:var(--brand2);background:rgba(106,76,224,.28)}
    .tabs{display:grid;grid-template-columns:repeat(3,1fr);background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:3px;gap:3px;margin-bottom:12px}
    .tab{min-height:38px;border-radius:9px;font-weight:600;color:var(--dim)}
    .tab.on{background:var(--panel2);color:var(--text)}
    h2{font-size:14px;font-weight:700;color:var(--dim);text-transform:uppercase;letter-spacing:.04em;margin:18px 2px 8px}
    .pane>h2:first-child,.pane>.hrow:first-child h2{margin-top:2px}
    .hrow{display:flex;align-items:center;gap:10px}
    .hrow h2{flex:1}
    .hrow select{width:auto;min-height:34px;font-size:14px}
    select{width:100%;min-height:44px;border-radius:11px;background:var(--panel2);border:1px solid var(--line);padding:0 12px;font-size:16px;-webkit-appearance:none;appearance:none;
      background-image:linear-gradient(45deg,transparent 50%,var(--dim) 50%),linear-gradient(135deg,var(--dim) 50%,transparent 50%);
      background-position:calc(100% - 18px) 50%,calc(100% - 12px) 50%;background-size:6px 6px;background-repeat:no-repeat;padding-right:32px}
    select:disabled{opacity:.4}
    .field{display:flex;gap:8px}
    .field select{flex:1}
    .icon{width:44px;min-height:44px;border-radius:11px;background:var(--panel2);border:1px solid var(--line);font-size:20px}
    .line{display:flex;align-items:center;gap:12px;min-height:46px;padding:4px 2px;border-bottom:1px solid var(--line)}
    .line:last-child,.line:has(+ .hidden:last-child){border-bottom:0}
    .line>span:first-child{flex:1}
    .line select{width:auto;max-width:60%}
    .slider{display:grid;grid-template-columns:minmax(90px,auto) 1fr 52px;align-items:center;gap:10px;min-height:44px}
    .val{font-size:13px;color:var(--dim);text-align:right;font-variant-numeric:tabular-nums}
    .switch{position:relative;width:51px;height:31px;border-radius:99px;background:rgba(255,255,255,.16);flex:none;transition:background .15s}
    .switch i{position:absolute;left:2px;top:2px;width:27px;height:27px;border-radius:50%;background:#fff;transition:left .15s;box-shadow:0 1px 3px rgba(0,0,0,.4)}
    .switch.on{background:var(--ok)}
    .switch.on i{left:22px}
    .switch:disabled{opacity:.35}
    .seg{display:inline-grid;grid-auto-flow:column;gap:2px;background:rgba(255,255,255,.08);border-radius:9px;padding:2px}
    .seg button{min-height:34px;padding:0 12px;border-radius:7px;font-size:14px;font-weight:600;color:var(--dim)}
    .seg button.on{background:var(--panel2);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.35)}
    .pick{display:inline-flex;align-items:center;min-height:38px;padding:0 14px;border-radius:10px;background:var(--panel2);border:1px solid var(--line);font-weight:600;font-size:15px;cursor:pointer}
    .group{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:4px 12px}
    /* Memes, logos, banners */
    .memes{display:grid;grid-template-columns:repeat(5,1fr);gap:7px}
    .meme{position:relative;aspect-ratio:16/10;border-radius:9px;overflow:hidden;background:var(--panel2);border:2px solid transparent;padding:0}
    .meme img{width:100%;height:100%;object-fit:cover;display:block}
    .meme .n{position:absolute;left:4px;top:3px;font-size:11px;font-weight:800;background:rgba(0,0,0,.6);border-radius:99px;padding:0 5px}
    .meme.empty{opacity:.35}
    .meme.on{border-color:var(--brand2);box-shadow:0 0 0 3px rgba(141,112,255,.35)}
    .tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:8px}
    .tw{position:relative}
    .tile{width:100%;min-height:60px;border-radius:11px;background:var(--panel2);border:2px solid transparent;padding:8px 10px;display:flex;align-items:center;gap:8px;text-align:left;overflow:hidden}
    .tile img{width:42px;height:42px;object-fit:contain;flex:none}
    .tile span{min-width:0}
    .tile b{display:block;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .tile small{display:block;color:var(--dim);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .tile.on{border-color:var(--brand2);background:rgba(106,76,224,.25)}
    .gear{position:absolute;right:4px;top:4px;width:28px;height:28px;border-radius:50%;background:rgba(0,0,0,.45);font-size:15px;line-height:28px;text-align:center}
    .gear.on{background:var(--brand)}
    .empty-note{color:var(--dim);font-size:14px;padding:4px 2px}
    /* Mixer */
    .ch{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:10px 12px;margin-bottom:8px}
    .ch-head{display:flex;align-items:center;gap:8px;font-weight:600}
    .ch-head .play{color:var(--ok);font-size:12px}
    .meter{flex:0 0 90px;height:6px;border-radius:9px;background:rgba(255,255,255,.12);overflow:hidden;margin-left:auto}
    .meter i{display:block;height:100%;width:0;background:var(--ok);border-radius:9px;transition:width .1s linear}
    .path{display:grid;grid-template-columns:96px 1fr 54px;align-items:center;gap:8px;margin-top:8px}
    .sw{min-height:34px;border-radius:9px;border:1.5px solid var(--line);font-size:13px;font-weight:600;color:var(--dim)}
    .sw.on{border-color:var(--brand2);color:var(--text);background:rgba(106,76,224,.25)}
    .sw:disabled{opacity:.35}
    input[type=range]{width:100%;accent-color:var(--brand2);height:30px;margin:0}
    input[type=range]:disabled{opacity:.35}
    .db{font-size:13px;color:var(--dim);text-align:right;font-variant-numeric:tabular-nums}
    .note{color:var(--dim);font-size:13px;margin-top:6px}
    .master{display:flex;align-items:center;gap:10px}
    .master .meter{flex:1}
    #offline,#toast{position:fixed;left:50%;transform:translateX(-50%);bottom:max(14px,env(safe-area-inset-bottom));background:var(--warn);color:#000;font-weight:600;border-radius:99px;padding:8px 16px;font-size:14px;max-width:92vw;text-align:center}
    #toast{background:var(--panel2);color:var(--text);border:1px solid var(--line);bottom:max(60px,calc(env(safe-area-inset-bottom) + 46px))}
    </style>
    </head>
    <body>
    <div id="pair"><div class="card"><img src="/icon.png" alt=""><h1>Erklärbär Live</h1><p id="pairText">Verbinde …</p><div class="spin" id="pairSpin"></div></div></div>
    <div id="app" class="hidden">
      <header>
        <div class="title"><span class="dot" id="liveDot"></span>Erklärbär Live</div>
        <div class="chips" id="chips"></div>
      </header>
      <div class="grid">
        <section class="stage">
          <div class="box">
            <div class="pv" id="pv"><img class="preview" id="preview" alt=""><div class="bubble hidden" id="bubble"></div></div>
            <div class="notice hidden" id="notice"><span id="noticeText"></span><button class="small hidden" id="restart">Wieder aufnehmen</button></div>
            <div class="row">
              <button class="big" id="mute"></button>
              <button class="big" id="rec"></button>
            </div>
            <div class="scenes">
              <button class="scene" data-scene="webcam"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="12" cy="10" r="3"/><path d="M6.5 18c1-2.6 3-4 5.5-4s4.5 1.4 5.5 4"/></svg>Nur Webcam</button>
              <button class="scene" data-scene="source"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="2.5" y="4" width="19" height="14" rx="2.5"/><path d="M8 21h8M2.5 8h19"/></svg>Quelle</button>
              <button class="scene" data-scene="sourceCam"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="2.5" y="4" width="19" height="14" rx="2.5"/><circle cx="16.5" cy="13" r="3.2"/></svg>Quelle + Webcam</button>
            </div>
          </div>
        </section>
        <section>
          <div class="tabs"><button class="tab on" data-tab="stage">Bühne</button><button class="tab" data-tab="picture">Bild</button><button class="tab" data-tab="sound">Ton</button></div>
          <div id="tab-stage" class="pane">
            <div class="hrow"><h2>Memes</h2><select id="memeSpot" data-set="memeSpot" aria-label="Position der Memes"></select></div>
            <div class="memes" id="memes"></div>
            <h2>Logos</h2><div class="tiles" id="logos"></div>
            <div class="group hidden" id="logoSettings" style="margin-top:8px">
              <div class="line"><span id="logoName">Logo</span><select id="logoCorner" data-logo="corner"></select></div>
              <div class="slider"><span>Größe</span><input type="range" id="logoSize" data-logo="size" min="0.05" max="0.4" step="0.01"><span class="val"></span></div>
              <div class="slider"><span>Deckkraft</span><input type="range" id="logoOpacity" data-logo="opacity" min="0.2" max="1" step="0.01"><span class="val"></span></div>
            </div>
            <h2>Banner</h2><div class="tiles" id="banners"></div>
          </div>
          <div id="tab-picture" class="pane hidden">
            <h2>Quelle</h2>
            <div class="field"><select id="source" data-set="source" aria-label="Quelle"></select><button class="icon" id="refresh" aria-label="Liste aktualisieren">⟳</button></div>
            <h2>Webcam</h2>
            <select id="camera" data-set="camera" aria-label="Webcam"></select>
            <div id="bubbleControls">
              <div class="slider"><span>Größe</span><input type="range" id="bubbleSize" data-set="bubbleSize" min="0.12" max="0.9" step="0.01"><span class="val"></span></div>
              <div class="note">Den gelben Kreis in der Vorschau mit dem Finger ziehen, um die Webcam zu verschieben.</div>
            </div>
            <h2>Rahmen</h2>
            <select id="mockup" data-set="mockup" aria-label="Rahmen"></select>
            <div class="note hidden" id="mockupNote">Rahmen gibt es bei den Szenen „Quelle“ und „Quelle + Webcam“.</div>
            <h2>Virtueller Hintergrund</h2>
            <div class="group">
              <div class="line"><span>Hinter dir</span><div class="seg" id="bgStyle"><button data-bg="real">Echt</button><button data-bg="blur">Unscharf</button><button data-bg="image">Bild</button></div></div>
              <div class="slider" id="bgBlurRow"><span>Unschärfe</span><input type="range" id="backgroundBlur" data-set="backgroundBlur" min="0" max="1" step="0.01"><span class="val"></span></div>
              <div class="line"><span class="note" style="margin:0" id="bgText">Ohne Greenscreen: Du stehst vor einem Bild.</span><label class="pick">Bild wählen …<input type="file" accept="image/*" id="bgFile" hidden></label></div>
              <div id="bgSliders">
                <div class="slider"><span>Kante</span><input type="range" id="backgroundEdge" data-set="backgroundEdge" min="0.1" max="0.9" step="0.01"><span class="val"></span></div>
                <div class="slider"><span>Beruhigen</span><input type="range" id="backgroundCalm" data-set="backgroundCalm" min="0" max="0.9" step="0.01"><span class="val"></span></div>
              </div>
            </div>
            <div id="effects">
              <h2>Effekte</h2>
              <div class="group">
                <div class="line"><span>Klick-Effekte</span><button class="switch" id="clicks" data-set="clicks"><i></i></button></div>
                <div class="line"><span>Mausspur</span><button class="switch" id="trail" data-set="trail"><i></i></button></div>
                <div class="line"><span>Tastenkürzel einblenden</span><button class="switch" id="keys" data-set="keys"><i></i></button></div>
              </div>
            </div>
          </div>
          <div id="tab-sound" class="pane hidden">
            <h2>Mikrofon</h2>
            <select id="microphone" data-set="microphone" aria-label="Mikrofon"></select>
            <div id="meetingBox">
              <h2>In Meetings als „Erklärbär“</h2>
              <div class="group">
                <div class="line" id="meetingCameraLine"><span>Kamera senden</span><button class="switch" id="meetingCamera" data-set="meetingCamera"><i></i></button></div>
                <div class="line" id="meetingMicrophoneLine"><span>Mikrofon senden</span><button class="switch" id="meetingMicrophone" data-set="meetingMicrophone"><i></i></button></div>
                <div class="line"><span>Meeting läuft in</span><select id="meetingApp" data-set="meetingApp" aria-label="Meeting-Programm"></select></div>
              </div>
            </div>
            <h2>Am Mac</h2>
            <div class="group">
              <div class="line"><span>Großes Programm-Fenster</span><button class="switch" id="showProgram" data-set="showProgram"><i></i></button></div>
            </div>
            <h2>Hören</h2>
            <div class="group">
              <div class="line"><span id="earName">–</span><span class="note" style="margin:0">Kopfhörer</span><button class="switch" id="headphones" data-set="headphones"><i></i></button></div>
            </div>
            <h2>Mischpult</h2>
            <div class="ch"><div class="master"><b>Ins Meeting</b><div class="meter"><i id="meter-meeting"></i></div></div></div>
            <div id="sources"></div>
            <h2>Programme</h2>
            <div id="apps"></div>
          </div>
        </section>
      </div>
    </div>
    <div id="offline" class="hidden">Verbindung zum Mac unterbrochen …</div>
    <div id="toast" class="hidden"></div>
    <script>
    "use strict";
    const $ = s => document.querySelector(s);
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
    const pct = v => Math.round(v * 100) + " %";
    const icons = {
      mic: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>',
      micOff: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M15 10V6a3 3 0 0 0-5.7-1.3M9 9v2a3 3 0 0 0 4.5 2.6M5 11a7 7 0 0 0 11.3 5.5M19 11a7 7 0 0 1-.6 2.8M12 18v3M3 3l18 18"/></svg>',
      rec: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="4.5" fill="currentColor"/></svg>',
      stop: '<svg viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2.5" fill="currentColor"/></svg>'
    };

    function randomID() {
      const a = new Uint8Array(12); crypto.getRandomValues(a);
      return Array.from(a, b => b.toString(16).padStart(2, "0")).join("");
    }
    function deviceName() {
      const ua = navigator.userAgent;
      if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return "iPad";
      if (/iPhone/.test(ua)) return "iPhone";
      if (/Android/.test(ua)) return "Android";
      return "Browser";
    }
    const query = new URLSearchParams(location.search);
    const secret = new URLSearchParams(location.hash.slice(1)).get("k");
    let token = query.get("d") || localStorage.getItem("ekb-token");
    let device = localStorage.getItem("ekb-device");
    if (!device) { device = randomID(); localStorage.setItem("ekb-device", device); }
    const auth = () => ({ "Authorization": "Bearer " + token });

    function showPair(text, busy) {
      $("#pair").classList.remove("hidden"); $("#app").classList.add("hidden");
      $("#pairText").textContent = text; $("#pairSpin").classList.toggle("hidden", !busy);
    }
    let toastTimer = null;
    function toast(text) {
      const t = $("#toast"); t.textContent = text; t.classList.remove("hidden");
      clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.add("hidden"), 3500);
    }
    async function check() {
      try { const r = await fetch("/api/hello", { headers: auth(), cache: "no-store" }); return r.ok ? true : (r.status === 401 ? false : null); }
      catch (e) { return null; }
    }
    async function pair() {
      showPair("Verbinde mit dem Mac …", true);
      const ask = async (url, body) => {
        const r = await fetch(url, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : { cache: "no-store" });
        return r.json();
      };
      try {
        let answer = await ask("/api/pair", { secret, device, name: deviceName() });
        while (answer.status === "waiting") {
          showPair("Bitte am Mac in der Live-Steuerung auf „Erlauben“ klicken.", true);
          await sleep(1000);
          answer = await ask("/api/pair/" + answer.request);
        }
        if (answer.status === "approved") {
          token = answer.token; localStorage.setItem("ekb-token", token);
          // The key goes into the address: "Zum Home-Bildschirm" keeps it (the home screen has its own storage).
          history.replaceState(null, "", "/?d=" + encodeURIComponent(token));
          return run();
        }
        showPair(answer.status === "denied" ? "Am Mac abgelehnt." : "Dieser QR-Code gilt nicht mehr. Bitte den aktuellen Code in der Live-Steuerung am Mac scannen.", false);
      } catch (e) {
        showPair("Der Mac antwortet nicht. Läuft Erklärbär Live und sind beide Geräte im selben WLAN?", false);
      }
    }
    function lost() {
      token = null; localStorage.removeItem("ekb-token");
      if (events) events.close();
      running = false;
      showPair("Dieses Gerät darf nicht mehr steuern. Bitte den QR-Code in der Live-Steuerung am Mac scannen.", false);
    }

    let running = false, events = null, state = null, lastSig = {}, editLogo = null, status = { fps: 0, recordingTime: 0 };
    // Only real changes touch the page: on iOS a change under the finger can turn a tap into a mere touch.
    function html(el, value) { if (el._html !== value) { el._html = value; el.innerHTML = value; } }
    function text(el, value) { if (el.textContent !== value) el.textContent = value; }
    function cls(el, value) { if (el.className !== value) el.className = value; }
    async function run() {
      running = true;
      $("#pair").classList.add("hidden"); $("#app").classList.remove("hidden");
      connect(); previewLoop(); keepAwake();
    }
    function connect() {
      if (events) events.close();
      events = new EventSource("/api/events?t=" + encodeURIComponent(token));
      events.addEventListener("state", e => { $("#offline").classList.add("hidden"); render(JSON.parse(e.data)); });
      events.addEventListener("levels", e => meters(JSON.parse(e.data)));
      events.addEventListener("status", e => { status = JSON.parse(e.data); renderHeader(); });
      events.onerror = async () => {
        $("#offline").classList.remove("hidden");
        if (await check() === false) lost();
      };
    }
    async function previewLoop() {
      const img = $("#preview");
      while (running) {
        if (document.hidden) { await sleep(600); continue; }
        try {
          const r = await fetch("/api/preview.jpg?t=" + encodeURIComponent(token) + "&n=" + Date.now(), { cache: "no-store" });
          if (r.status === 401) return lost();
          if (r.ok) {
            const url = URL.createObjectURL(await r.blob());
            const old = img.dataset.url; img.src = url; img.dataset.url = url;
            if (old) setTimeout(() => URL.revokeObjectURL(old), 1000);
          }
        } catch (e) { await sleep(800); }
        await sleep(160);
      }
    }
    async function keepAwake() {
      try { if ("wakeLock" in navigator && !document.hidden) await navigator.wakeLock.request("screen"); } catch (e) {}
    }
    document.addEventListener("visibilitychange", () => { if (!document.hidden && running) { keepAwake(); if (!events || events.readyState === 2) connect(); } });

    async function send(body) {
      try {
        const r = await fetch("/api/command", { method: "POST", headers: { ...auth(), "Content-Type": "application/json" }, body: JSON.stringify(body) });
        if (r.status === 401) lost();
        return r.ok;
      } catch (e) { $("#offline").classList.remove("hidden"); return false; }
    }
    function busy(el, ms) {
      el.dataset.busy = "1";
      clearTimeout(el._busy); el._busy = setTimeout(() => { delete el.dataset.busy; }, ms || 900);
    }

    function time(s) { s = Math.floor(s); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); }
    function db(v) { v = Math.round(v); return (v > 0 ? "+" : "") + v + " dB"; }

    // Controls in use are left alone (open picker, finger on a slider): neither rebuilt nor reset.
    function inUse(el) { return document.activeElement === el || (el._hold || 0) > Date.now() || !!el.dataset.busy; }
    function options(sel, groups, value, placeholder) {
      if (inUse(sel)) return;
      const sig = JSON.stringify([groups, placeholder]);
      if (sel.dataset.sig !== sig) {
        sel.dataset.sig = sig;
        let html = placeholder ? '<option value="">' + esc(placeholder) + "</option>" : "";
        for (const g of groups) {
          const opts = g.items.map(i => '<option value="' + esc(i.id) + '">' + esc(i.name) + "</option>").join("");
          html += g.label ? (g.items.length ? '<optgroup label="' + esc(g.label) + '">' + opts + "</optgroup>" : "") : opts;
        }
        sel.innerHTML = html;
      }
      const known = Array.from(sel.options).some(o => o.value === value);
      const wanted = known ? value : (placeholder !== undefined ? "" : sel.value);
      if (sel.value !== wanted) sel.value = wanted;
    }
    function slider(el, value, format) {
      if (el.dataset.busy) return;
      if (Number(el.value) !== value) el.value = value;
      text(el.parentElement.querySelector(".val"), format(value));
    }
    function toggle(el, on, disabled) {
      if (!el.dataset.busy) el.classList.toggle("on", !!on);
      el.disabled = !!disabled;
    }

    function renderHeader() {
      const s = state; if (!s) return;
      const chips = [];
      if (s.recording) chips.push('<span class="chip rec">● ' + time(status.recordingTime) + "</span>");
      chips.push('<span class="chip">' + status.fps + " Bilder/s</span>");
      if (s.meetingMic === "running") chips.push('<span class="chip">Mikrofon „Erklärbär“</span>');
      else if (s.meetingMic === "missing" || s.meetingMic === "failed") chips.push('<span class="chip warn">Mikrofon gestört</span>');
      html($("#chips"), chips.join(""));
      html($("#rec"), s.recording ? icons.stop + "Stopp " + time(status.recordingTime) : icons.rec + "Aufnehmen");
    }

    function render(s) {
      state = s;
      renderHeader();
      $("#liveDot").classList.toggle("off", !s.live);
      // Notices
      const notice = s.sourceLost || s.message;
      $("#notice").classList.toggle("hidden", !notice);
      text($("#noticeText"), notice || "");
      $("#restart").classList.toggle("hidden", !s.sourceLost);
      // Mute, record, scenes
      cls($("#mute"), "big" + (s.muted ? " muted" : ""));
      html($("#mute"), s.muted ? icons.micOff + "Stimme aus" : icons.mic + "Stumm");
      cls($("#rec"), "big" + (s.recording ? " recording" : ""));
      document.querySelectorAll(".scene").forEach(b => b.classList.toggle("on", b.dataset.scene === s.scene));
      renderBubble(s);
      renderStage(s);
      renderPicture(s);
      renderSound(s);
    }

    // Webcam bubble on the preview: drag to move it.
    let drag = null;
    function renderBubble(s) {
      const b = $("#bubble");
      const shown = s.scene === "sourceCam" && s.camera;
      b.classList.toggle("hidden", !shown);
      if (!shown || drag) return;
      placeBubble(s.bubble.cx, s.bubble.cy, s.bubble.d);
    }
    function placeBubble(cx, cy, d) {
      const b = $("#bubble");
      const set = (key, value) => { if (b.style[key] !== value) b.style[key] = value; };
      set("left", (cx * 100).toFixed(2) + "%"); set("top", (cy * 100).toFixed(2) + "%"); set("width", (d * 56.25).toFixed(2) + "%");
    }
    $("#bubble").addEventListener("pointerdown", e => {
      if (!state) return;
      e.preventDefault();
      $("#bubble").setPointerCapture(e.pointerId);
      const rect = $("#pv").getBoundingClientRect();
      drag = { x: e.clientX, y: e.clientY, bx: state.bubble.x, by: state.bubble.y, w: rect.width, h: rect.height, sent: 0, nx: state.bubble.x, ny: state.bubble.y };
      $("#bubble").classList.add("drag");
    });
    $("#bubble").addEventListener("pointermove", e => {
      if (!drag) return;
      const half = state.bubble.d / 2, halfX = half * 9 / 16;
      drag.nx = Math.min(1, Math.max(0, drag.bx + (e.clientX - drag.x) / drag.w));
      drag.ny = Math.min(1, Math.max(0, drag.by + (e.clientY - drag.y) / drag.h));
      placeBubble(Math.min(1 - halfX, Math.max(halfX, drag.nx)), Math.min(1 - half, Math.max(half, drag.ny)), state.bubble.d);
      const now = Date.now();
      if (now - drag.sent > 70) { drag.sent = now; send({ action: "set", key: "bubble", value: { x: drag.nx, y: drag.ny } }); }
    });
    function endDrag() {
      if (!drag) return;
      send({ action: "set", key: "bubble", value: { x: drag.nx, y: drag.ny } });
      $("#bubble").classList.remove("drag");
      setTimeout(() => { drag = null; }, 400);
    }
    $("#bubble").addEventListener("pointerup", endDrag);
    $("#bubble").addEventListener("pointercancel", endDrag);

    function renderStage(s) {
      options($("#memeSpot"), [{ items: s.memeSpots }], s.memeSpot);
      const memeSig = s.memes.map(m => m.empty ? "-" : m.title).join("|");
      if (lastSig.memes !== memeSig) {
        lastSig.memes = memeSig;
        $("#memes").innerHTML = s.memes.map(m => {
          const n = (m.index + 1) % 10;
          if (m.empty) return '<button class="meme empty" disabled><span class="n">' + n + "</span></button>";
          return '<button class="meme" data-meme="' + m.index + '" title="' + esc(m.title) + '"><img src="/api/meme/' + m.index + ".jpg?t=" + encodeURIComponent(token) + "&v=" + encodeURIComponent(m.title) + '" alt=""><span class="n">' + n + "</span></button>";
        }).join("");
      }
      s.memes.forEach(m => { const b = document.querySelector('[data-meme="' + m.index + '"]'); if (b) b.classList.toggle("on", !!m.playing); });
      const logoSig = s.logos.map(l => l.id + l.name).join("|");
      if (lastSig.logos !== logoSig) {
        lastSig.logos = logoSig;
        $("#logos").innerHTML = s.logos.length ? s.logos.map(l => '<div class="tw"><button class="tile" data-logo-toggle="' + l.id + '"><img src="/api/logo/' + l.id + ".png?t=" + encodeURIComponent(token) + '" alt=""><span><b>' + esc(l.name) + '</b></span></button><button class="gear" data-logo-edit="' + l.id + '" aria-label="Einstellungen">⚙︎</button></div>').join("")
          : '<div class="empty-note">Logos legst du in der Live-Steuerung am Mac an.</div>';
      }
      s.logos.forEach(l => {
        const b = document.querySelector('[data-logo-toggle="' + l.id + '"]'); if (b) b.classList.toggle("on", l.on);
        const g = document.querySelector('[data-logo-edit="' + l.id + '"]'); if (g) g.classList.toggle("on", editLogo === l.id);
      });
      const logo = s.logos.find(l => l.id === editLogo);
      $("#logoSettings").classList.toggle("hidden", !logo);
      if (logo) {
        text($("#logoName"), logo.name);
        options($("#logoCorner"), [{ items: s.corners }], logo.corner);
        slider($("#logoSize"), logo.size, pct);
        slider($("#logoOpacity"), logo.opacity, pct);
      }
      const bannerSig = s.banners.map(b => b.id + b.title + b.subtitle).join("|");
      if (lastSig.banners !== bannerSig) {
        lastSig.banners = bannerSig;
        $("#banners").innerHTML = s.banners.length ? s.banners.map(b => '<button class="tile" data-banner="' + b.id + '"><span><b>' + esc(b.title || "Banner") + "</b><small>" + esc(b.subtitle) + "</small></span></button>").join("")
          : '<div class="empty-note">Banner legst du in der Live-Steuerung am Mac an.</div>';
      }
      s.banners.forEach(b => { const t = document.querySelector('[data-banner="' + b.id + '"]'); if (t) t.classList.toggle("on", b.on); });
    }

    function renderPicture(s) {
      options($("#source"), [
        { label: "Bildschirme", items: s.videoSources.displays },
        { label: "iPad und iPhone am Kabel", items: s.videoSources.devices },
        { label: "Fenster", items: s.videoSources.windows }
      ], s.source, "– Quelle wählen –");
      options($("#camera"), [{ items: [{ id: "", name: "Aus" }].concat(s.cameras) }], s.camera);
      $("#bubbleControls").classList.toggle("hidden", !(s.scene === "sourceCam" && s.camera));
      slider($("#bubbleSize"), s.bubble.size, pct);
      const framed = s.scene !== "webcam";
      options($("#mockup"), [{ items: [{ id: "", name: "Ohne" }].concat(s.mockups) }], s.mockup);
      $("#mockup").disabled = !framed;
      $("#mockupNote").classList.toggle("hidden", framed);
      document.querySelectorAll("[data-bg]").forEach(b => b.classList.toggle("on", b.dataset.bg === s.backgroundStyle));
      $("#bgBlurRow").classList.toggle("hidden", s.backgroundStyle !== "blur");
      slider($("#backgroundBlur"), s.backgroundBlur, pct);
      text($("#bgText"), s.backgroundImage ? "Anderes Bild vom iPhone oder iPad:" : "Erst ein Bild wählen, z. B. ein Foto:");
      $("#bgSliders").classList.toggle("hidden", !s.background);
      slider($("#backgroundEdge"), s.backgroundEdge, pct);
      slider($("#backgroundCalm"), s.backgroundCalm, pct);
      $("#effects").classList.toggle("hidden", s.isDevice);
      toggle($("#clicks"), s.clicks); toggle($("#trail"), s.trail); toggle($("#keys"), s.keys);
    }

    function renderSound(s) {
      options($("#microphone"), [{ items: [{ id: "", name: "Aus" }].concat(s.microphones) }], s.microphone);
      $("#microphone").disabled = s.recording;
      const cam = s.meetingCamera, mic = s.meetingMicrophone;
      $("#meetingBox").classList.toggle("hidden", !cam.shown && !mic.shown);
      $("#meetingCameraLine").classList.toggle("hidden", !cam.shown);
      $("#meetingMicrophoneLine").classList.toggle("hidden", !mic.shown);
      toggle($("#meetingCamera"), cam.ready && cam.sending, !cam.ready);
      toggle($("#meetingMicrophone"), mic.ready && mic.sending, !mic.ready);
      const apps = s.runningApps.slice();
      if (s.meetingApp && !apps.some(a => a.id === s.meetingApp)) apps.unshift({ id: s.meetingApp, name: s.meetingApp });
      options($("#meetingApp"), [{ items: [{ id: "", name: "–" }].concat(apps) }], s.meetingApp);
      text($("#earName"), s.ear ? s.ear.name : "Keine Tonausgabe");
      toggle($("#headphones"), s.ear && s.ear.headphones, !s.ear);
      toggle($("#showProgram"), s.showProgram);
      renderMixer(s);
    }

    function pathRow(source, path, mix, allowed, label) {
      const on = path === "meeting" ? mix.meetingOn : mix.earOn;
      const value = path === "meeting" ? mix.meeting : mix.ear;
      return '<div class="path" data-source="' + esc(source) + '" data-path="' + path + '">' +
        '<button class="sw' + (on ? " on" : "") + '"' + (allowed ? "" : " disabled") + ">" + label + "</button>" +
        '<input type="range" min="' + state.range[0] + '" max="' + state.range[1] + '" step="1" value="' + value + '"' + (allowed && on ? "" : " disabled") + ">" +
        '<span class="db">' + db(value) + "</span></div>";
    }
    function renderMixer(s) {
      const sig = JSON.stringify([s.sources.map(x => [x.id, x.earAllowed]), s.apps.map(a => [a.id, a.isMeeting, a.playing])]);
      const busyRow = document.querySelector(".path[data-busy]");
      if (lastSig.mixer !== sig && !busyRow) {
        lastSig.mixer = sig;
        $("#sources").innerHTML = s.sources.map(x =>
          '<div class="ch"><div class="ch-head">' + esc(x.name) + '<div class="meter"><i id="meter-' + x.id + '"></i></div></div>' +
          pathRow(x.id, "meeting", x.mix, true, "Meeting") + pathRow(x.id, "ear", x.mix, x.earAllowed, "Ohr") +
          (x.id === "voice" && !x.earAllowed ? '<div class="note">Ins Ohr nur mit Kopfhörern – aus Lautsprechern nähme das Mikrofon deine Stimme wieder auf.</div>' : "") +
          "</div>").join("");
        $("#apps").innerHTML = s.apps.length ? s.apps.map(a =>
          '<div class="ch"><div class="ch-head">' + esc(a.name) + (a.playing ? ' <span class="play">♪</span>' : "") +
          (a.isMeeting ? "" : '<div class="meter"><i id="meter-app-' + esc(a.id) + '"></i></div>') + "</div>" +
          (a.isMeeting ? '<div class="note">Meeting-Programm: Die Stimmen der anderen gehen nie zurück ins Meeting.</div>'
                       : pathRow("app:" + a.id, "meeting", a.mix, true, "Meeting")) + "</div>").join("")
          : '<div class="empty-note">Spielt am Mac ein Programm Ton ab, erscheint es hier. Ins Meeting geht es erst, wenn du es einschaltest.</div>';
      }
      const all = s.sources.map(x => [x.id, x.mix, x.earAllowed]).concat(s.apps.filter(a => !a.isMeeting).map(a => ["app:" + a.id, a.mix, true]));
      all.forEach(([id, mix, earAllowed]) => {
        ["meeting", "ear"].forEach(path => {
          const row = document.querySelector('.path[data-source="' + CSS.escape(id) + '"][data-path="' + path + '"]');
          if (!row || row.dataset.busy) return;
          const on = path === "meeting" ? mix.meetingOn : mix.earOn;
          const value = path === "meeting" ? mix.meeting : mix.ear;
          const allowed = path === "meeting" || earAllowed;
          row.querySelector(".sw").classList.toggle("on", on);
          const range = row.querySelector("input");
          range.value = value; range.disabled = !(allowed && on);
          text(row.querySelector(".db"), db(value));
        });
      });
    }
    function meters(l) {
      const set = (id, v) => { const el = document.getElementById(id); if (el) el.style.width = Math.min(100, Math.sqrt(v || 0) * 100) + "%"; };
      set("meter-voice", l.voice); set("meter-device", l.device); set("meter-memes", l.memes); set("meter-meeting", l.meeting);
      for (const id in l.apps) set("meter-app-" + id, l.apps[id]);
    }

    function showTab(name) {
      document.querySelectorAll(".tab").forEach(b => b.classList.toggle("on", b.dataset.tab === name));
      ["stage", "picture", "sound"].forEach(t => $("#tab-" + t).classList.toggle("hidden", t !== name));
      // Windows come and go: the list is fresh when the tab opens.
      if (name === "picture") send({ action: "refreshSources" });
    }

    // Taps
    document.addEventListener("click", e => {
      const t = e.target.closest("button"); if (!t || t.disabled || !state) return;
      if (t.id === "mute") send({ action: "mute", value: !state.muted });
      else if (t.id === "rec") send({ action: "record" });
      else if (t.id === "restart") send({ action: "restartSource" });
      else if (t.id === "refresh") { send({ action: "refreshSources" }); toast("Liste wird aktualisiert …"); }
      else if (t.dataset.scene) { send({ action: "scene", value: t.dataset.scene }); document.querySelectorAll(".scene").forEach(b => b.classList.toggle("on", b === t)); }
      else if (t.dataset.meme) send({ action: "meme", index: Number(t.dataset.meme) });
      else if (t.dataset.logoToggle) send({ action: "logo", id: t.dataset.logoToggle });
      else if (t.dataset.logoEdit) { editLogo = editLogo === t.dataset.logoEdit ? null : t.dataset.logoEdit; render(state); }
      else if (t.dataset.banner) send({ action: "banner", id: t.dataset.banner });
      else if (t.dataset.bg) {
        if (t.dataset.bg === "image" && !state.backgroundImage) { $("#bgFile").click(); return; }
        document.querySelectorAll("[data-bg]").forEach(b => b.classList.toggle("on", b === t));
        send({ action: "set", key: "backgroundStyle", value: t.dataset.bg });
      }
      else if (t.dataset.tab) showTab(t.dataset.tab);
      else if (t.classList.contains("switch") && t.dataset.set) {
        const on = !t.classList.contains("on");
        if (t.dataset.set === "background" && on && !state.backgroundImage) { $("#bgFile").click(); return; }
        t.classList.toggle("on", on); busy(t);
        send({ action: "set", key: t.dataset.set, value: on });
      } else if (t.classList.contains("sw")) {
        const row = t.closest(".path"); const on = !t.classList.contains("on");
        t.classList.toggle("on", on); row.querySelector("input").disabled = !on;
        send({ action: "mix", source: row.dataset.source, path: row.dataset.path, on });
      }
    });
    // A list that is touched stays as it is until the choice is made (iOS opens its picker a moment later).
    const hold = e => { const el = e.target; if (el && el.tagName === "SELECT") el._hold = Date.now() + 2500; };
    document.addEventListener("pointerdown", hold, true);
    document.addEventListener("touchstart", hold, { capture: true, passive: true });
    document.addEventListener("focusin", hold);
    function chosen(el) {
      clearTimeout(el._send);
      el._send = null;
      if (el.dataset.set) send({ action: "set", key: el.dataset.set, value: el.value });
      else if (el.dataset.logo && editLogo) send({ action: "logoSettings", id: editLogo, [el.dataset.logo]: el.value });
    }
    document.addEventListener("change", e => {
      const el = e.target; if (el.tagName !== "SELECT") return;
      el._hold = Date.now() + 2500; busy(el, 2500);
      // The wheel on the iPhone reports every step: switch once it has come to rest (a new source takes a moment).
      clearTimeout(el._send);
      el._send = setTimeout(() => chosen(el), el.id === "source" ? 600 : 200);
    });
    document.addEventListener("focusout", e => {
      const el = e.target; if (el.tagName !== "SELECT") return;
      if (el._send) chosen(el);
      el._hold = Date.now() + 1200;
    });
    let lastSent = 0, finalTimer = null;
    document.addEventListener("input", e => {
      const el = e.target; if (el.type !== "range") return;
      const value = Number(el.value);
      let body;
      if (el.dataset.set) { busy(el, 700); el.parentElement.querySelector(".val").textContent = pct(value); body = { action: "set", key: el.dataset.set, value }; }
      else if (el.dataset.logo && editLogo) { busy(el, 700); el.parentElement.querySelector(".val").textContent = pct(value); body = { action: "logoSettings", id: editLogo, [el.dataset.logo]: value }; }
      else {
        const row = el.closest(".path"); if (!row) return;
        row.dataset.busy = "1"; clearTimeout(row._busy); row._busy = setTimeout(() => { delete row.dataset.busy; }, 700);
        row.querySelector(".db").textContent = db(value);
        body = { action: "mix", source: row.dataset.source, path: row.dataset.path, db: value };
      }
      const now = Date.now();
      if (now - lastSent > 90) { lastSent = now; send(body); }
      clearTimeout(finalTimer); finalTimer = setTimeout(() => send(body), 250);
    });
    $("#bgFile").addEventListener("change", async e => {
      const file = e.target.files && e.target.files[0]; if (!file) return;
      toast("Bild wird übertragen …");
      try {
        const r = await fetch("/api/background", { method: "POST", headers: { ...auth(), "Content-Type": file.type || "image/jpeg" }, body: file });
        toast(r.ok ? "Hintergrund gesetzt" : "Das Bild ließ sich nicht übernehmen.");
      } catch (err) { toast("Das Bild ließ sich nicht übertragen."); }
      e.target.value = "";
    });

    (async () => {
      if (token) {
        const ok = await check();
        if (ok) return run();
        if (ok === null && !secret) return showPair("Der Mac antwortet nicht. Läuft Erklärbär Live und ist die Fernsteuerung eingeschaltet?", false);
        if (ok === false) { token = null; localStorage.removeItem("ekb-token"); }
      }
      if (secret) return pair();
      showPair("Am Mac in der Live-Steuerung die Fernsteuerung einschalten und den QR-Code mit der Kamera scannen.", false);
    })();
    </script>
    </body>
    </html>
    """#
}
