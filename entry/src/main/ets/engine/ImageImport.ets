/**
 * Image import helpers.
 *
 * The system decoder (ImageSource) understands png / jpeg / bmp / gif / webp /
 * dng / heic / heif / tiff, but it cannot open camera raw files from other
 * vendors (CR2/CR3, NEF/NRW, ARW, ORF, RAF, RW2, PEF, SRW, 3FR, IIF, KDC, MRW,
 * ERF ...). Every one of those containers embeds a ready-made JPEG preview, so
 * instead of demosaicing the sensor data we locate the largest valid JPEG
 * stream inside the file and hand that to the system decoder. That mirrors what
 * the reference app exposes as "raw import": the visible result is the camera's
 * own rendering of the frame.
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

/** Suffix filters handed to the document picker, gallery images first. */
export const IMAGE_SUFFIX_FILTER: string =
  '图片/相机原始|.jpg,.jpeg,.png,.webp,.bmp,.gif,.heic,.heif,.tif,.tiff,' +
  '.dng,.cr2,.cr3,.nef,.nrw,.arw,.srf,.sr2,.orf,.raf,.rw2,.rwl,.pef,.srw,' +
  '.3fr,.fff,.iiq,.kdc,.mrw,.erf';

/** Files we route through the embedded-preview extractor when the system
 *  decoder refuses them. */
const RAW_SUFFIXES: string[] = [
  'cr2', 'cr3', 'crw', 'nef', 'nrw', 'arw', 'srf', 'sr2', 'orf', 'raf',
  'rw2', 'rwl', 'pef', 'srw', '3fr', 'fff', 'iiq', 'kdc', 'mrw', 'erf'
];

export function uriExtension(uri: string): string {
  const clean: string = uri.split('?')[0];
  const slash: number = clean.lastIndexOf('/');
  const name: string = slash >= 0 ? clean.substring(slash + 1) : clean;
  const dot: number = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
}

export function isRawExtension(ext: string): boolean {
  return RAW_SUFFIXES.indexOf(ext) >= 0;
}

export class OpenedImage {
  source: image.ImageSource;
  /** True when the pixels came from the embedded JPEG preview. */
  fromPreview: boolean;
  /** Name of the container that was actually decoded. */
  format: string;
  private closer: () => void;

  constructor(source: image.ImageSource, fromPreview: boolean, format: string, closer: () => void) {
    this.source = source;
    this.fromPreview = fromPreview;
    this.format = format;
    this.closer = closer;
  }

  release(): void {
    this.closer();
  }
}

function closeQuietly(file: fs.File | undefined): void {
  if (file === undefined) {
    return;
  }
  try {
    fs.closeSync(file);
  } catch (e) {
    // The fd is already gone; nothing useful to do here.
  }
}

function readWholeFile(uri: string): Uint8Array {
  const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  try {
    const size: number = fs.statSync(uri).size;
    if (size <= 0) {
      throw new Error('empty file');
    }
    const buf: ArrayBuffer = new ArrayBuffer(size);
    let read: number = 0;
    while (read < size) {
      const n: number = fs.readSync(file.fd, buf, { offset: read, length: size - read });
      if (n <= 0) {
        break;
      }
      read += n;
    }
    return new Uint8Array(buf, 0, read);
  } finally {
    closeQuietly(file);
  }
}

function u16be(b: Uint8Array, o: number): number {
  return (b[o] << 8) | b[o + 1];
}

interface JpegSpan {
  width: number;
  height: number;
  start: number;
  end: number;
}

/** Walk one JPEG stream: validate the marker chain, read the SOF size and find
 *  the matching EOI. Returns undefined for anything that is not a complete,
 *  sane JPEG image. */
function probeJpeg(b: Uint8Array, start: number): JpegSpan | undefined {
  const n: number = b.length;
  if (start + 3 >= n || b[start] !== 0xFF || b[start + 1] !== 0xD8 || b[start + 2] !== 0xFF) {
    return undefined;
  }
  let p: number = start + 2;
  let width: number = 0;
  let height: number = 0;
  let components: number = 0;
  while (p + 1 < n) {
    if (b[p] !== 0xFF) {
      return undefined;
    }
    let m: number = b[p + 1];
    while (m === 0xFF && p + 2 < n) {
      p++;
      m = b[p + 1];
    }
    if (m === 0xD9) {
      break;
    }
    // Standalone markers: TEM, RST0..RST7.
    if (m === 0x01 || (m >= 0xD0 && m <= 0xD7)) {
      p += 2;
      continue;
    }
    if (p + 4 > n) {
      return undefined;
    }
    const len: number = u16be(b, p + 2);
    if (len < 2 || p + 2 + len > n) {
      return undefined;
    }
    if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) {
      const seg: number = p + 4;
      if (seg + 5 >= n) {
        return undefined;
      }
      height = u16be(b, seg + 1);
      width = u16be(b, seg + 3);
      components = b[seg + 5];
    }
    p += 2 + len;
    if (m !== 0xDA) {
      continue;
    }
    // Entropy-coded data: advance to the next real marker, honouring byte
    // stuffing and restart markers.
    while (p + 1 < n) {
      if (b[p] !== 0xFF) {
        p++;
        continue;
      }
      const next: number = b[p + 1];
      if (next === 0x00 || (next >= 0xD0 && next <= 0xD7) || next === 0xFF) {
        p += next === 0xFF ? 1 : 2;
        continue;
      }
      break;
    }
    if (b[p] === 0xFF && b[p + 1] === 0xD9) {
      if (width > 0 && height > 0 && components > 0) {
        return { width: width, height: height, start: start, end: p + 2 };
      }
      return undefined;
    }
  }
  // Ran out of file before EOI: the stream is truncated, not a usable preview.
  return undefined;
}

/**
 * Largest complete JPEG preview inside a container (raw files, CR3, TIFF with
 * a preview IFD, ...). Vendor raw streams never contain a byte-aligned JPEG by
 * accident, and the probe rejects anything that is not a full image, so a plain
 * "biggest valid JPEG" scan is safe across vendors.
 */
export function extractJpegPreview(bytes: Uint8Array): Uint8Array | undefined {
  const n: number = bytes.length;
  let best: JpegSpan | undefined = undefined;
  let i: number = 0;
  while (i + 2 < n) {
    if (bytes[i] !== 0xFF || bytes[i + 1] !== 0xD8 || bytes[i + 2] !== 0xFF) {
      i += 1;
      continue;
    }
    const span: JpegSpan | undefined = probeJpeg(bytes, i);
    if (span !== undefined && span.width >= 160 && span.height >= 120) {
      if (best === undefined ||
        span.width * span.height > best.width * best.height) {
        best = span;
      }
    }
    i += 2;
  }
  if (best === undefined) {
    return undefined;
  }
  return bytes.slice(best.start, best.end);
}

/** Opens a picked image. Tries the platform decoder first and falls back to the
 *  embedded JPEG preview for camera raw containers. */
export async function openImageSource(uri: string): Promise<OpenedImage> {
  const ext: string = uriExtension(uri);
  if (!isRawExtension(ext)) {
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const source: image.ImageSource = image.createImageSource(file.fd);
      await source.getImageInfo();
      const handle: fs.File = file;
      return new OpenedImage(source, false, ext, () => closeQuietly(handle));
    } catch (e) {
      closeQuietly(file);
    }
  }

  const bytes: Uint8Array = readWholeFile(uri);
  const preview: Uint8Array | undefined = extractJpegPreview(bytes);
  if (preview === undefined) {
    throw new Error('未找到内嵌预览 / no embedded preview (.' + ext + ')');
  }
  const source: image.ImageSource = image.createImageSource(preview.buffer as ArrayBuffer);
  await source.getImageInfo();
  // Nothing to close: the source owns the copied preview buffer.
  return new OpenedImage(source, true, ext, () => {});
}
