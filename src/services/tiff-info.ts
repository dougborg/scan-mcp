import { promises as fs } from "fs";

/**
 * Minimal, dependency-free TIFF header reader: parses the first IFD to recover a
 * page's pixel dimensions, bit depth, and compression. Used to enrich the job
 * manifest for backends that don't report image metrics themselves (e.g. SANE),
 * and as a fallback when the macOS helper's per-page metrics are unavailable.
 *
 * Best-effort: any malformed/unsupported file yields an empty object rather than
 * throwing, so manifest writing never fails on a page it can't measure.
 */
export type TiffInfo = {
  width?: number;
  height?: number;
  bits_per_sample?: number;
  compression?: string;
};

// TIFF compression tag (259) values we care to name; others fall through to the
// raw number so the manifest still records something useful.
const COMPRESSION_NAMES: Record<number, string> = {
  1: "none",
  2: "ccitt_rle",
  3: "ccitt_g3",
  4: "ccitt_g4",
  5: "lzw",
  6: "jpeg_old",
  7: "jpeg",
  8: "deflate",
  32773: "packbits",
};

export async function readTiffInfo(path: string): Promise<TiffInfo> {
  try {
    const buf = await fs.readFile(path);
    if (buf.length < 8) return {};

    let little: boolean;
    const bom = buf.toString("ascii", 0, 2);
    if (bom === "II") little = true;
    else if (bom === "MM") little = false;
    else return {};

    const u16 = (off: number) => (little ? buf.readUInt16LE(off) : buf.readUInt16BE(off));
    const u32 = (off: number) => (little ? buf.readUInt32LE(off) : buf.readUInt32BE(off));

    if (u16(2) !== 42) return {}; // TIFF magic

    const ifdOffset = u32(4);
    if (ifdOffset + 2 > buf.length) return {};

    const entryCount = u16(ifdOffset);
    const info: TiffInfo = {};

    for (let i = 0; i < entryCount; i++) {
      const entry = ifdOffset + 2 + i * 12;
      if (entry + 12 > buf.length) break;
      const tag = u16(entry);
      const type = u16(entry + 2);
      // SHORT (type 3) values live in the first 2 bytes of the value field;
      // LONG (type 4) values occupy all 4. That covers every tag we read.
      const value = type === 3 ? u16(entry + 8) : u32(entry + 8);
      switch (tag) {
        case 256: info.width = value; break;
        case 257: info.height = value; break;
        case 258: info.bits_per_sample = value; break;
        case 259: info.compression = COMPRESSION_NAMES[value] ?? String(value); break;
      }
    }
    return info;
  } catch {
    return {};
  }
}
