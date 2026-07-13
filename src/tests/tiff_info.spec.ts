import { describe, it, expect, beforeAll, afterAll } from "vitest";
import fs from "fs";
import os from "os";
import path from "path";
import { readTiffInfo } from "../services/tiff-info.js";

// Build a minimal but valid little-endian TIFF with a single IFD carrying the
// four tags readTiffInfo cares about (width, height, bits, compression).
function makeTiff(width: number, height: number, bits: number, compression: number): Buffer {
  const entries = [
    [256, width],
    [257, height],
    [258, bits],
    [259, compression],
  ];
  const ifdOffset = 8;
  const size = ifdOffset + 2 + entries.length * 12 + 4;
  const buf = Buffer.alloc(size);
  buf.write("II", 0, "ascii");
  buf.writeUInt16LE(42, 2);
  buf.writeUInt32LE(ifdOffset, 4);
  buf.writeUInt16LE(entries.length, ifdOffset);
  entries.forEach(([tag, value], i) => {
    const off = ifdOffset + 2 + i * 12;
    buf.writeUInt16LE(tag, off); // tag
    buf.writeUInt16LE(3, off + 2); // type SHORT
    buf.writeUInt32LE(1, off + 4); // count
    buf.writeUInt16LE(value, off + 8); // value (in-line for SHORT)
  });
  return buf;
}

describe("readTiffInfo", () => {
  let dir: string;
  beforeAll(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "tiffinfo-"));
  });
  afterAll(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("parses dimensions, bit depth, and compression", async () => {
    const p = path.join(dir, "g4.tiff");
    fs.writeFileSync(p, makeTiff(1700, 2200, 1, 4));
    const info = await readTiffInfo(p);
    expect(info.width).toBe(1700);
    expect(info.height).toBe(2200);
    expect(info.bits_per_sample).toBe(1);
    expect(info.compression).toBe("ccitt_g4");
  });

  it("names unknown compression by its raw number", async () => {
    const p = path.join(dir, "weird.tiff");
    fs.writeFileSync(p, makeTiff(10, 20, 8, 99));
    const info = await readTiffInfo(p);
    expect(info.compression).toBe("99");
  });

  it("returns empty object for non-TIFF data", async () => {
    const p = path.join(dir, "nope.bin");
    fs.writeFileSync(p, "this is not a tiff");
    expect(await readTiffInfo(p)).toEqual({});
  });

  it("returns empty object for a missing file", async () => {
    expect(await readTiffInfo(path.join(dir, "ghost.tiff"))).toEqual({});
  });
});
