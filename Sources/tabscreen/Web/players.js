'use strict';

// Dos formas de mostrar el video, con la misma interfaz:
//  - WebCodecs: decodifica cada cuadro apenas llega y lo pinta en un canvas.
//    Latencia mínima, pero Chrome solo lo permite en contextos seguros
//    (https o localhost, como por cable USB con adb reverse).
//  - MSE: empaqueta los cuadros como MP4 fragmentado para un <video>. Funciona
//    por http en la red local, con algo más de retraso.
//
// player.configure(config)        config = { width, height, fps, sps, pps }
// player.push(data, isKeyframe)   un cuadro AVCC
// player.stats()                  { shown, dropped } acumulados y lagMs actual
// player.onNeedKeyframe           lo llama el reproductor cuando necesita uno
const Players = (() => {
  const TIMESCALE = 90000;

  function webCodecs(canvas) {
    const player = { onNeedKeyframe() {} };
    const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    const receivedAt = new Map(); // timestamp → momento en que llegó el cuadro
    const totals = { shown: 0, dropped: 0 };
    let decoder = null;
    let config = null;
    let waitingForKeyframe = true;
    let timestamp = 0;
    let lagMs = 0;
    let failures = 0;

    function output(frame) {
      const arrived = receivedAt.get(frame.timestamp);
      receivedAt.delete(frame.timestamp);
      if (arrived !== undefined) lagMs = lagMs * 0.9 + (performance.now() - arrived) * 0.1;
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      ctx.drawImage(frame, 0, 0);
      frame.close();
      totals.shown += 1;
      failures = 0;
    }

    function fail(err) {
      console.warn('VideoDecoder falló', err);
      failures += 1;
      if (config && failures <= 5) {
        setTimeout(() => {
          player.configure(config);
          player.onNeedKeyframe();
        }, 500);
      }
    }

    player.configure = (next) => {
      config = next;
      if (decoder && decoder.state !== 'closed') decoder.close();
      decoder = new VideoDecoder({ output, error: fail });
      decoder.configure({
        codec: FMP4.codecString(next.sps),
        codedWidth: next.width,
        codedHeight: next.height,
        description: FMP4.avcConfigRecord(next.sps, next.pps),
        optimizeForLatency: true,
      });
      waitingForKeyframe = true;
      receivedAt.clear();
    };

    player.push = (data, isKeyframe) => {
      if (!decoder || decoder.state !== 'configured') return;
      if (waitingForKeyframe) {
        if (!isKeyframe) return;
        waitingForKeyframe = false;
      }
      // Si el decodificador no da abasto se descarta hasta el próximo keyframe,
      // en vez de acumular retraso.
      if (!isKeyframe && decoder.decodeQueueSize > 2) {
        totals.dropped += 1;
        waitingForKeyframe = true;
        player.onNeedKeyframe();
        return;
      }
      timestamp += 16667;
      if (receivedAt.size > 120) receivedAt.clear();
      receivedAt.set(timestamp, performance.now());
      decoder.decode(new EncodedVideoChunk({ type: isKeyframe ? 'key' : 'delta', timestamp, data }));
    };

    player.stats = () => ({ shown: totals.shown, dropped: totals.dropped, lagMs });
    return player;
  }

  function mse(video) {
    const player = { onNeedKeyframe() {} };
    const base = { shown: 0, dropped: 0 }; // acumulado de reproductores anteriores
    let mediaSource = null;
    let sourceBuffer = null;
    let pending = [];
    let mime = '';
    let config = null;
    let sequence = 1;
    let decodeTime = 0;
    let frameDuration = TIMESCALE / 60;
    let waitingForKeyframe = true;
    let seekToKeyframe = false; // se pidió un keyframe para saltar a él
    let pendingSeek = null;     // tiempo del keyframe al que saltar

    const quality = () => (video.getVideoPlaybackQuality
      ? video.getVideoPlaybackQuality()
      : { totalVideoFrames: 0, droppedVideoFrames: 0 });

    const bufferLag = () => (video.buffered.length
      ? video.buffered.end(video.buffered.length - 1) - video.currentTime
      : 0);

    player.configure = (next) => {
      const nextMime = `video/mp4; codecs="${FMP4.codecString(next.sps)}"`;
      if (!window.MediaSource || !MediaSource.isTypeSupported(nextMime)) {
        throw new Error(`Este navegador no puede reproducir ${nextMime}. Usa Chrome.`);
      }
      config = next;
      mime = nextMime;
      setup();
    };

    function setup() {
      const q = quality();
      base.shown += q.totalVideoFrames - q.droppedVideoFrames;
      base.dropped += q.droppedVideoFrames;

      frameDuration = Math.round(TIMESCALE / config.fps);
      pending = [FMP4.initSegment({ ...config, timescale: TIMESCALE })];
      sequence = 1;
      decodeTime = 0;
      waitingForKeyframe = true;
      seekToKeyframe = false;
      pendingSeek = null;
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
    }

    player.push = (data, isKeyframe) => {
      if (!config) return;
      if (waitingForKeyframe && !isKeyframe) return;
      waitingForKeyframe = false;
      if (isKeyframe && seekToKeyframe) {
        pendingSeek = decodeTime / TIMESCALE;
        seekToKeyframe = false;
      }
      pending.push(FMP4.mediaSegment(sequence++, decodeTime, frameDuration, data, isKeyframe));
      decodeTime += frameDuration;
      flush();
    };

    function flush() {
      if (!sourceBuffer || sourceBuffer.updating || pending.length === 0) return;
      if (mediaSource.readyState !== 'open') return;
      const chunk = pending.length === 1 ? pending[0] : concat(pending);
      pending = [];
      try {
        sourceBuffer.appendBuffer(chunk);
      } catch (err) {
        console.warn('appendBuffer falló, reiniciando', err);
        resync();
      }
    }

    function concat(chunks) {
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
      setup();
      player.onNeedKeyframe();
    }

    video.addEventListener('error', () => resync());

    // Mantiene la latencia baja. Un atraso pequeño se recupera acelerando; uno
    // grande, pidiendo un keyframe y saltando a él (saltar a cualquier otro
    // punto obliga a Chrome a decodificar todo desde el keyframe anterior).
    // También libera búfer viejo.
    setInterval(() => {
      if (!sourceBuffer || video.buffered.length === 0) return;
      const end = video.buffered.end(video.buffered.length - 1);
      if (pendingSeek !== null && end >= pendingSeek) {
        video.currentTime = pendingSeek;
        pendingSeek = null;
      }
      const lag = end - video.currentTime;
      if (lag > 0.5 && !seekToKeyframe && pendingSeek === null) {
        seekToKeyframe = true;
        player.onNeedKeyframe();
      }
      video.playbackRate = lag > 0.15 ? 1.5 : lag > 0.05 ? 1.15 : 1.0;
      if (video.paused) video.play().catch(() => {});

      const start = video.buffered.start(0);
      if (!sourceBuffer.updating && video.currentTime - start > 30) {
        try { sourceBuffer.remove(start, video.currentTime - 10); } catch (_) { /* reintenta luego */ }
      }
    }, 100);

    player.stats = () => {
      const q = quality();
      return {
        shown: base.shown + q.totalVideoFrames - q.droppedVideoFrames,
        dropped: base.dropped + q.droppedVideoFrames,
        lagMs: bufferLag() * 1000,
      };
    };
    return player;
  }

  return { webCodecs, mse };
})();
