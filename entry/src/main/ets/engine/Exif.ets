/**
 * Minimal EXIF (APP1/TIFF) writer for exported JPEGs.
 *
 * HarmonyOS' ImagePacker writes no metadata, so the JPEG produced by the packer
 * is patched by hand: a little-endian TIFF header with a single IFD0 carrying
 * ImageDescription, Software and DateTime. That mirrors the tags the desktop
 * reference writes on export.
 */

interface IfdEntry {
  tag: number;
  text: string;
}

const TAG_DESCRIPTION: number = 0x010E;
const TAG_SOFTWARE: number = 0x0131;
const TAG_DATETIME: number = 0x0132;

function strBytes(s: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    out.push(s.charCodeAt(i) & 0xFF);
  }
  return out;
}

function two(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

/** EXIF expects "YYYY:MM:DD HH:MM:SS". */
export function exifTimestamp(d: Date): string {
  return d.getFullYear().toString() + ':' + two(d.getMonth() + 1) + ':' + two(d.getDate()) +
    ' ' + two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds());
}

function buildTiff(tags: IfdEntry[]): Uint8Array {
  const n: number = tags.length;
  const ifdSize: number = 2 + n * 12 + 4;
  const dataStart: number = 8 + ifdSize;
  const chunks: number[][] = [];
  const offsets: number[] = [];
  let cursor: number = dataStart;
  for (let i = 0; i < n; i++) {
    const bytes: number[] = strBytes(tags[i].text);
    bytes.push(0);
    if (bytes.length % 2 !== 0) {
      bytes.push(0);
    }
    offsets.push(cursor);
    chunks.push(bytes);
    cursor += bytes.length;
  }
  const tiff: Uint8Array = new Uint8Array(cursor);
  tiff[0] = 0x49;  // "II": little endian
  tiff[1] = 0x49;
  tiff[2] = 0x2A;  // 42
  tiff[3] = 0x00;
  tiff[4] = 0x08;  // IFD0 offset
  tiff[8] = n & 0xFF;
  tiff[9] = 0;
  for (let i = 0; i < n; i++) {
    const e: number = 10 + i * 12;
    const tag: number = tags[i].tag;
    const count: number = chunks[i].length;
    tiff[e] = tag & 0xFF;
    tiff[e + 1] = (tag >> 8) & 0xFF;
    tiff[e + 2] = 0x02;  // ASCII
    tiff[e + 3] = 0x00;
    tiff[e + 4] = count & 0xFF;
    tiff[e + 5] = (count >> 8) & 0xFF;
    tiff[e + 6] = (count >> 16) & 0xFF;
    tiff[e + 7] = (count >> 24) & 0xFF;
    if (count <= 4) {
      for (let k = 0; k < 4; k++) {
        tiff[e + 8 + k] = k < count ? chunks[i][k] : 0;
      }
    } else {
      const off: number = offsets[i];
      tiff[e + 8] = off & 0xFF;
      tiff[e + 9] = (off >> 8) & 0xFF;
      tiff[e + 10] = (off >> 16) & 0xFF;
      tiff[e + 11] = (off >> 24) & 0xFF;
      for (let k = 0; k < count; k++) {
        tiff[off + k] = chunks[i][k];
      }
    }
  }
  return tiff;
}

/** Build a ready-to-insert APP1 segment (Exif\0\0 + TIFF IFD0). */
export function buildExifApp1(description: string, software: string, timestamp: string): Uint8Array {
  const tags: IfdEntry[] = [
    { tag: TAG_DESCRIPTION, text: description },
    { tag: TAG_SOFTWARE, text: software },
    { tag: TAG_DATETIME, text: timestamp }
  ];
  const tiff: Uint8Array = buildTiff(tags);
  const segLen: number = 2 + 6 + tiff.length;
  const app1: Uint8Array = new Uint8Array(2 + segLen);
  app1[0] = 0xFF;
  app1[1] = 0xE1;
  // JPEG segment lengths are big-endian (this used to be written the other
  // way round, which made decoders swallow the first 42 KB of pixel data and
  // the exported file would not display).
  app1[2] = (segLen >> 8) & 0xFF;
  app1[3] = segLen & 0xFF;
  app1[4] = 0x45;  // E
  app1[5] = 0x78;  // x
  app1[6] = 0x69;  // i
  app1[7] = 0x66;  // f
  app1[8] = 0x00;
  app1[9] = 0x00;
  for (let i = 0; i < tiff.length; i++) {
    app1[10 + i] = tiff[i];
  }
  return app1;
}

/** Insert an APP1 segment right after the JPEG SOI marker. */
export function insertExif(jpeg: Uint8Array, app1: Uint8Array): Uint8Array {
  if (jpeg.length < 2 || jpeg[0] !== 0xFF || jpeg[1] !== 0xD8) {
    return jpeg;
  }
  const out: Uint8Array = new Uint8Array(jpeg.length + app1.length);
  out[0] = jpeg[0];
  out[1] = jpeg[1];
  out.set(app1, 2);
  out.set(jpeg.subarray(2), 2 + app1.length);
  return out;
}
