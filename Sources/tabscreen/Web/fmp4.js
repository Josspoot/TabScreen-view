'use strict';

// Muxer mínimo de MP4 fragmentado (fMP4) para H.264, para alimentar
// Media Source Extensions. Cada cuadro AVCC se empaqueta como un
// fragmento moof+mdat con una sola muestra.
const FMP4 = (() => {
  const u16 = (n) => [(n >>> 8) & 255, n & 255];
  const u32 = (n) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
  const str = (s) => Array.from(s, (c) => c.charCodeAt(0));
  const zeros = (n) => new Uint8Array(n);
  const MATRIX = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000].flatMap(u32);

  function concat(parts) {
    const arrays = parts.map((p) => (p instanceof Uint8Array ? p : new Uint8Array(p)));
    const out = new Uint8Array(arrays.reduce((n, a) => n + a.length, 0));
    let offset = 0;
    for (const a of arrays) {
      out.set(a, offset);
      offset += a.length;
    }
    return out;
  }

  function box(type, ...payload) {
    const body = concat(payload);
    const out = new Uint8Array(8 + body.length);
    out.set(u32(out.length), 0);
    out.set(str(type), 4);
    out.set(body, 8);
    return out;
  }

  const fullBox = (type, version, flags, ...payload) =>
    box(type, [version, (flags >>> 16) & 255, (flags >>> 8) & 255, flags & 255], ...payload);

  function codecString(sps) {
    return 'avc1.' + [sps[1], sps[2], sps[3]].map((b) => b.toString(16).padStart(2, '0')).join('');
  }

  // AVCDecoderConfigurationRecord: el contenido de la caja avcC, y la
  // "description" que pide WebCodecs.
  function avcConfigRecord(sps, pps) {
    return concat([
      [1, sps[1], sps[2], sps[3], 0xff /* NAL de 4 bytes */, 0xe1 /* 1 SPS */], u16(sps.length), sps,
      [1], u16(pps.length), pps,
    ]);
  }

  const avcC = (sps, pps) => box('avcC', avcConfigRecord(sps, pps));

  function initSegment({ width, height, sps, pps, timescale }) {
    const ftyp = box('ftyp', str('isom'), u32(0x200), str('isom'), str('iso6'), str('avc1'), str('mp41'));
    const mvhd = fullBox('mvhd', 0, 0,
      u32(0), u32(0), u32(1000), u32(0), u32(0x00010000), u16(0x0100), zeros(10), MATRIX, zeros(24), u32(2));
    const tkhd = fullBox('tkhd', 0, 3,
      u32(0), u32(0), u32(1), u32(0), u32(0), zeros(8), u16(0), u16(0), u16(0), u16(0), MATRIX,
      u32(width * 65536), u32(height * 65536));
    const mdhd = fullBox('mdhd', 0, 0, u32(0), u32(0), u32(timescale), u32(0), u16(0x55c4), u16(0));
    const hdlr = fullBox('hdlr', 0, 0, u32(0), str('vide'), zeros(12), str('VideoHandler'), [0]);
    const avc1 = box('avc1',
      zeros(6), u16(1), zeros(16), u16(width), u16(height), u32(0x00480000), u32(0x00480000),
      u32(0), u16(1), zeros(32), u16(0x0018), u16(0xffff), avcC(sps, pps));
    const stbl = box('stbl',
      fullBox('stsd', 0, 0, u32(1), avc1),
      fullBox('stts', 0, 0, u32(0)),
      fullBox('stsc', 0, 0, u32(0)),
      fullBox('stsz', 0, 0, u32(0), u32(0)),
      fullBox('stco', 0, 0, u32(0)));
    const minf = box('minf',
      fullBox('vmhd', 0, 1, zeros(8)),
      box('dinf', fullBox('dref', 0, 0, u32(1), fullBox('url ', 0, 1))),
      stbl);
    const trak = box('trak', tkhd, box('mdia', mdhd, hdlr, minf));
    const mvex = box('mvex', fullBox('trex', 0, 0, u32(1), u32(1), u32(0), u32(0), u32(0)));
    return concat([ftyp, box('moov', mvhd, trak, mvex)]);
  }

  function mediaSegment(sequence, decodeTime, duration, data, isKeyframe) {
    const sampleFlags = isKeyframe ? 0x02000000 : 0x01010000;
    const mfhd = fullBox('mfhd', 0, 0, u32(sequence));
    const tfhd = fullBox('tfhd', 0, 0x020000 /* default-base-is-moof */, u32(1));
    const tfdt = fullBox('tfdt', 1, 0, u32(Math.floor(decodeTime / 4294967296)), u32(decodeTime >>> 0));
    const trun = fullBox('trun', 0, 0x000701 /* offset, duración, tamaño, flags */,
      u32(1), u32(0), u32(duration), u32(data.length), u32(sampleFlags));
    const moof = box('moof', mfhd, box('traf', tfhd, tfdt, trun));
    // data_offset: desde el inicio de moof hasta los datos dentro de mdat.
    const dataOffsetPos = 8 + mfhd.length + 8 + tfhd.length + tfdt.length + 12 + 4;
    moof.set(u32(moof.length + 8), dataOffsetPos);
    return concat([moof, box('mdat', data)]);
  }

  return { codecString, avcConfigRecord, initSegment, mediaSegment };
})();
