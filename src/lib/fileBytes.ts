// Created by Claude — Classification: INTERNAL
//
// Raw bytes of a local file for the image/PDF viewers (`read_file_bytes`, a binary
// IPC response). Rendering from memory avoids the asset protocol, whose path scope
// silently refused files under dot-folders.

import { invoke } from "@tauri-apps/api/core";

export async function readFileBytes(path: string): Promise<ArrayBuffer> {
  const res = await invoke<ArrayBuffer | Uint8Array | number[]>("read_file_bytes", { path });
  if (res instanceof ArrayBuffer) return res;
  if (res instanceof Uint8Array) return res.slice().buffer as ArrayBuffer;
  return new Uint8Array(res).buffer; // older IPC shapes: a plain number array
}

const IMAGE_MIME: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  bmp: "image/bmp",
  ico: "image/x-icon",
  svg: "image/svg+xml",
};

export function imageMime(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return IMAGE_MIME[ext] ?? "application/octet-stream";
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
