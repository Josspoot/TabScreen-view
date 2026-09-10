'use strict';

(() => {
  const TIMESCALE = 90000;
  const token = new URLSearchParams(location.search).get('t') || '';

  const video = document.getElementById('screen');
  const overlay = document.getElementById('overlay');
  const statusEl = document.getElementById('status');
  const deviceEl = document.getElementById('device');
  const statsEl = document.getElementById('stats');
  const startBtn = document.getElementById('start');
  const showStats = document.getElementById('show-stats');

  // Resolución física de la tablet (lado largo x lado corto).
  const w = Math.round(screen.width * devicePixelRatio);
  const h = Math.round(screen.height * devicePixelRatio);
  const nativeRes = `${Math.max(w, h)}x${Math.min(w, h)}`;
  deviceEl.textContent = `Resolución de esta tablet: ${nativeRes}`;

  let ws = null;
  let mediaSource = null;
  let sourceBuffer = null;
  let pending = [];
  let config = null;
  let configKey = '';
  let sequence = 1;
  let decodeTime = 0;
  let frameDuration = TIMESCALE / 60;
  let waitingForKeyframe = true;
  const counters = { frames: 0, bytes: 0 };

  const setStatus = (text) => { statusEl.textContent = text; };

  // --- Conexión -----------------------------------------------------------

  function connect() {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${scheme}://${location.host}/ws?t=${encodeURIComponent(token)}`);
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => {
      setStatus('Conectado. Esperando video…');
      send({ type: 'hello', screen: nativeRes, dpr: devicePixelRatio, ua: navigator.userAgent });
    };
    ws.onmessage = (event) => handleMessage(new Uint8Array(event.data));
    ws.onclose = () => {
      setStatus('Sin conexión con la Mac. Reintentando…');
      overlay.hidden = false;
      configKey = '';
      setTimeout(connect, 1500);
    };
  }

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
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
      setupMediaSource();
    } else if (msg[0] === 0x02) {
      if (!config) return;
      const isKeyframe = (msg[1] & 1) === 1;
      if (waitingForKeyframe && !isKeyframe) return;
      waitingForKeyframe = false;
      const data = msg.subarray(10);
      pending.push(FMP4.mediaSegment(sequence++, decodeTime, frameDuration, data, isKeyframe));
      decodeTime += frameDuration;
      counters.frames += 1;
      counters.bytes += msg.length;
      flush();
    }
  }

  // --- Reproducción (Media Source Extensions) -----------------------------

  function setupMediaSource() {
    const mime = `video/mp4; codecs="${FMP4.codecString(config.sps)}"`;
    if (!window.MediaSource || !MediaSource.isTypeSupported(mime)) {
      setStatus(`Este navegador no puede reproducir ${mime}. Usa Chrome.`);
      return;
    }
    frameDuration = Math.round(TIMESCALE / config.fps);
    pending = [FMP4.initSegment({ ...config, timescale: TIMESCALE })];
    sequence = 1;
    decodeTime = 0;
    waitingForKeyframe = true;
    sourceBuffer = null;

    mediaSource = new MediaSource();
    const ms = mediaSource;
    video.src = URL.createObjectURL(ms);
    ms.addEventListener('sourceopen', () => {
      URL.revokeObjectURL(video.src);
      if (ms !== mediaSource) return;
      sourceBuffer = ms.addSourceBuffer(mime);
      sourceBuffer.addEventListener('updateend', flush);
      flush();
    }, { once: true });
    video.play().catch(() => {});
    setStatus(`Recibiendo ${config.width}x${config.height} @ ${config.fps} fps`);
  }

  function flush() {
    if (!sourceBuffer || sourceBuffer.updating || pending.length === 0) return;
    if (mediaSource.readyState !== 'open') return;
    const chunk = pending.length === 1 ? pending[0] : concatChunks(pending);
    pending = [];
    try {
      sourceBuffer.appendBuffer(chunk);
    } catch (err) {
      console.warn('appendBuffer falló, reiniciando', err);
      resync();
    }
  }

  function concatChunks(chunks) {
    const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
    let offset = 0;
    for (const c of chunks) {
      out.set(c, offset);
      offset += c.length;
    }
    return out;
  }

  function resync() {
    if (!config) return;
    setupMediaSource();
    send({ type: 'keyframe' });
  }

  video.addEventListener('error', () => resync());

  // Mantiene la latencia baja: si el video se atrasa, lo acelera o salta
  // al final del búfer. También libera búfer viejo.
  setInterval(() => {
    if (!sourceBuffer || video.buffered.length === 0) return;
    const end = video.buffered.end(video.buffered.length - 1);
    const lag = end - video.currentTime;
    if (lag > 1.0) {
      video.currentTime = end - 0.05;
    } else {
      video.playbackRate = lag > 0.25 ? 1.5 : lag > 0.1 ? 1.1 : 1.0;
    }
    if (video.paused) video.play().catch(() => {});

    const start = video.buffered.start(0);
    if (!sourceBuffer.updating && video.currentTime - start > 30) {
      try { sourceBuffer.remove(start, video.currentTime - 10); } catch (_) { /* reintenta luego */ }
    }
  }, 200);

  setInterval(() => {
    if (!showStats.checked || !config) return;
    const lag = video.buffered.length ? video.buffered.end(video.buffered.length - 1) - video.currentTime : 0;
    statsEl.textContent =
      `${config.width}x${config.height}  ${counters.frames} fps  ` +
      `${(counters.bytes * 8 / 1e6).toFixed(1)} Mbps  retraso ${Math.round(lag * 1000)} ms`;
    counters.frames = 0;
    counters.bytes = 0;
  }, 1000);

  // --- Interfaz -----------------------------------------------------------

  startBtn.addEventListener('click', async () => {
    try { await document.documentElement.requestFullscreen({ navigationUI: 'hide' }); } catch (_) {}
    try { await screen.orientation.lock('landscape'); } catch (_) {}
    overlay.hidden = true;
    video.play().catch(() => {});
  });

  showStats.addEventListener('change', () => { statsEl.hidden = !showStats.checked; });

  document.addEventListener('dblclick', (event) => {
    if (event.target.closest('.card')) return;
    overlay.hidden = !overlay.hidden;
  });

  if (!token) {
    setStatus('Falta el token. Escanea el QR que muestra la Mac.');
  } else {
    connect();
  }
})();
