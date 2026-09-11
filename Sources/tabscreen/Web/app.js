'use strict';

(() => {
  const params = new URLSearchParams(location.search);
  const token = params.get('t') || '';

  const $ = (id) => document.getElementById(id);
  const video = $('video');
  const canvas = $('canvas');
  const overlay = $('overlay');
  const statusEl = $('status');
  const deviceEl = $('device');
  const statsEl = $('stats');
  const startBtn = $('start');
  const showStats = $('show-stats');
  const pairEl = $('pair');
  const pairCode = $('pair-code');
  const controls = $('controls');
  const positionButtons = document.querySelectorAll('[data-side]');

  // WebCodecs (latencia mínima) solo existe en contextos seguros: por cable USB
  // la página se abre como localhost y lo es; por Wi-Fi (http://IP) se usa MSE.
  // ?mode=mse fuerza MSE.
  const useWebCodecs = params.get('mode') !== 'mse' && window.isSecureContext && 'VideoDecoder' in window;
  const player = useWebCodecs ? Players.webCodecs(canvas) : Players.mse(video);
  const modeLabel = useWebCodecs ? 'WebCodecs' : 'MSE';
  canvas.hidden = !useWebCodecs;
  video.hidden = useWebCodecs;
  player.onNeedKeyframe = () => send({ type: 'keyframe' });

  // Resolución física del dispositivo (lado largo x lado corto).
  const w = Math.round(screen.width * devicePixelRatio);
  const h = Math.round(screen.height * devicePixelRatio);
  const nativeRes = `${Math.max(w, h)}x${Math.min(w, h)}`;

  // Identidad persistente, para que la Mac pueda "recordar" este dispositivo.
  const deviceId = loadDeviceId();
  const deviceName = `${guessDeviceName()} · ${deviceId.slice(0, 4)}`;
  deviceEl.textContent = `${deviceName} — ${nativeRes} — ${modeLabel}`;

  let ws = null;
  let approved = false;
  let rejected = false;
  let config = null;
  let configKey = '';
  let receivedTotal = 0;
  let bytesTotal = 0;

  const setStatus = (text) => { statusEl.textContent = text; };

  function loadDeviceId() {
    let id = null;
    try { id = localStorage.getItem('tabscreen-device-id'); } catch (_) {}
    if (!id || !/^[0-9a-f]{32}$/.test(id)) {
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      id = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      try { localStorage.setItem('tabscreen-device-id', id); } catch (_) {}
    }
    return id;
  }

  function guessDeviceName() {
    const ua = navigator.userAgent;
    const model = ((ua.match(/Android [\d.]+; ([^;)]+)/) || [])[1] || '').trim();
    if (model && model !== 'K') return model; // Chrome reciente oculta el modelo como "K"
    // En tablets, Chrome suele pedir "versión de escritorio" y se presenta como Linux.
    if (/Android|Linux/.test(ua) && navigator.maxTouchPoints > 0) return 'Tablet Android';
    if (/iPad|Macintosh/.test(ua)) return 'iPad';
    return 'Navegador';
  }

  // --- Conexión -----------------------------------------------------------

  function connect() {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${scheme}://${location.host}/ws?t=${encodeURIComponent(token)}`);
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => {
      setStatus('Conectado. Esperando autorización de la Mac…');
      send({ type: 'hello', deviceId, name: deviceName, screen: nativeRes });
    };
    ws.onmessage = (event) => {
      if (typeof event.data === 'string') handleControl(event.data);
      else handleMessage(new Uint8Array(event.data));
    };
    ws.onclose = () => {
      approved = false;
      configKey = '';
      pairEl.hidden = true;
      controls.hidden = true;
      overlay.hidden = false;
      if (rejected) return; // no insistir: cada intento abriría otra ventana en la Mac
      setStatus('Sin conexión con la Mac. Reintentando…');
      setTimeout(connect, 1500);
    };
  }

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }

  function handleControl(text) {
    let msg;
    try { msg = JSON.parse(text); } catch (_) { return; }
    if (msg.type === 'pair') {
      setStatus('Esta Mac necesita confirmar este dispositivo.');
      pairCode.textContent = `${msg.code.slice(0, 3)} ${msg.code.slice(3)}`;
      pairEl.hidden = false;
      overlay.hidden = false;
    } else if (msg.type === 'approved') {
      approved = true;
      pairEl.hidden = true;
      controls.hidden = false;
      setStatus('Conexión permitida. Esperando video…');
      keepAwake();
    } else if (msg.type === 'rejected') {
      rejected = true;
      pairEl.hidden = true;
      controls.hidden = true;
      overlay.hidden = false;
      setStatus(`${msg.reason} Recarga la página para intentarlo de nuevo.`);
    } else if (msg.type === 'position') {
      positionButtons.forEach((b) => b.classList.toggle('active', b.dataset.side === msg.side));
    }
  }

  function handleMessage(msg) {
    if (msg[0] === 0x01) {
      const view = new DataView(msg.buffer, msg.byteOffset, msg.byteLength);
      const spsLength = view.getUint16(6);
      const ppsLength = view.getUint16(8 + spsLength);
      const key = msg.subarray(1).join(',');
      if (key === configKey) return;
      configKey = key;
      config = {
        width: view.getUint16(1),
        height: view.getUint16(3),
        fps: msg[5] || 60,
        sps: msg.slice(8, 8 + spsLength),
        pps: msg.slice(10 + spsLength, 10 + spsLength + ppsLength),
      };
      try {
        player.configure(config);
        setStatus(`Recibiendo ${config.width}x${config.height} @ ${config.fps} fps · ${modeLabel}`);
      } catch (err) {
        setStatus(err.message);
      }
    } else if (msg[0] === 0x02) {
      if (!config) return;
      receivedTotal += 1;
      bytesTotal += msg.length;
      player.push(msg.subarray(10), (msg[1] & 1) === 1);
    }
  }

  // --- Estadísticas -------------------------------------------------------

  // Cada consumidor (panel en pantalla, reporte a la Mac) mide su propia ventana.
  function statsMeter() {
    const snapshot = () => {
      const s = player.stats();
      return { t: performance.now(), received: receivedTotal, bytes: bytesTotal, shown: s.shown, dropped: s.dropped, lagMs: s.lagMs };
    };
    let last = snapshot();
    return () => {
      const now = snapshot();
      const prev = last;
      last = now;
      const secs = Math.max((now.t - prev.t) / 1000, 0.001);
      const rate = (k) => Math.round((now[k] - prev[k]) / secs);
      return {
        received: rate('received'),
        shown: rate('shown'),
        dropped: rate('dropped'),
        mbps: (now.bytes - prev.bytes) * 8 / secs / 1e6,
        lag: Math.round(now.lagMs),
      };
    };
  }

  const overlayMeter = statsMeter();
  setInterval(() => {
    if (!showStats.checked || !config) return;
    const s = overlayMeter();
    statsEl.textContent = `${config.width}x${config.height} · ${modeLabel}  ${s.shown} fps  `
      + `${s.mbps.toFixed(1)} Mbps  retraso ${s.lag} ms`;
  }, 1000);

  // Cada 10 s la tablet le cuenta a la Mac cómo le va (se ve en la terminal).
  const reportMeter = statsMeter();
  setInterval(() => {
    if (!approved || !config) return;
    const s = reportMeter();
    send({ type: 'stats', mode: modeLabel, received: s.received, shown: s.shown, dropped: s.dropped, lag: s.lag });
  }, 10000);

  // --- Interfaz -----------------------------------------------------------

  // Evita que la pantalla se apague (solo en contextos seguros, p. ej. por USB).
  async function keepAwake() {
    try {
      if (navigator.wakeLock && document.visibilityState === 'visible') await navigator.wakeLock.request('screen');
    } catch (_) { /* no disponible */ }
  }
  document.addEventListener('visibilitychange', keepAwake);

  startBtn.addEventListener('click', async (event) => {
    event.stopPropagation();
    overlay.hidden = true;
    if (!useWebCodecs) video.play().catch(() => {});
    keepAwake();
    try { await document.documentElement.requestFullscreen({ navigationUI: 'hide' }); } catch (_) {}
    try { await screen.orientation.lock('landscape'); } catch (_) {}
  });

  positionButtons.forEach((button) => {
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      send({ type: 'position', side: button.dataset.side });
    });
  });

  showStats.addEventListener('change', () => { statsEl.hidden = !showStats.checked; });

  // Tocar fuera del panel lo cierra; doble toque en la pantalla lo vuelve a
  // abrir. Se detecta a mano porque dblclick no siempre llega en táctiles.
  // Mientras la Mac no apruebe el dispositivo, el panel se queda visible.
  let lastTap = 0;
  document.addEventListener('pointerup', (event) => {
    if (!approved || event.target.closest('.card')) return;
    if (!overlay.hidden) {
      overlay.hidden = true;
      lastTap = 0;
      return;
    }
    const now = Date.now();
    if (now - lastTap < 350) {
      overlay.hidden = false;
      lastTap = 0;
    } else {
      lastTap = now;
    }
  });

  if (!token) {
    setStatus('Falta el token. Escanea el QR que muestra la Mac.');
  } else {
    connect();
  }
})();
