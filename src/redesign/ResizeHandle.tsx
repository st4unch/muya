// Created by Claude — Classification: INTERNAL
//
// Drag handle on a panel's inner edge: a 5px hit area laid over the panel's existing
// 1px border. Pointer capture keeps the drag alive over the terminal (an xterm under
// the cursor would otherwise steal the events) and needs no window listeners, so
// nothing can leak if the panel unmounts mid-drag. Double-click resets.
//
// `side` is the panel edge the handle sits on: "right" (left panel, grows with +dx),
// "left" (right panel, grows with -dx) or "top" (a bottom section, grows with -dy).

import { useRef, type PointerEvent as ReactPointerEvent, type KeyboardEvent } from "react";

export type HandleSide = "right" | "left" | "top";

export interface ResizeHandleProps {
  side: HandleSide;
  /** Current size in px; default = the parent panel's own width (or height for "top"). */
  getSize?: () => number;
  /** Largest allowed size, evaluated at drag start (depends on the container). */
  getMax?: () => number;
  min: number;
  max: number;
  onResize: (px: number) => void;
  onReset: () => void;
  label: string;
}

export function clampSize(px: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, Math.round(px)));
}

export function ResizeHandle({ side, getSize, getMax, min, max, onResize, onReset, label }: ResizeHandleProps) {
  const drag = useRef<{ start: number; size: number; max: number } | null>(null);
  const vertical = side === "top";

  function coord(e: { clientX: number; clientY: number }) {
    return vertical ? e.clientY : e.clientX;
  }
  function sizeOf(el: HTMLElement) {
    if (getSize) return getSize();
    const parent = el.parentElement;
    return parent ? (vertical ? parent.offsetHeight : parent.clientWidth) : min;
  }
  function onPointerDown(e: ReactPointerEvent<HTMLDivElement>) {
    if (e.button !== 0) return;
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    drag.current = { start: coord(e), size: sizeOf(e.currentTarget), max: Math.min(max, getMax ? getMax() : max) };
    e.currentTarget.dataset.dragging = "true";
  }
  function onPointerMove(e: ReactPointerEvent<HTMLDivElement>) {
    const d = drag.current;
    if (!d) return;
    const delta = coord(e) - d.start;
    const grow = side === "right" ? delta : -delta;
    onResize(clampSize(d.size + grow, min, Math.max(min, d.max)));
  }
  function end(e: ReactPointerEvent<HTMLDivElement>) {
    drag.current = null;
    delete e.currentTarget.dataset.dragging;
    if (e.currentTarget.hasPointerCapture?.(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId);
  }
  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    const step = e.shiftKey ? 32 : 8;
    const dir: Record<string, number> = vertical ? { ArrowUp: 1, ArrowDown: -1 } : side === "right" ? { ArrowRight: 1, ArrowLeft: -1 } : { ArrowLeft: 1, ArrowRight: -1 };
    const sign = dir[e.key];
    if (!sign) return;
    e.preventDefault();
    onResize(clampSize(sizeOf(e.currentTarget) + sign * step, min, Math.max(min, getMax ? Math.min(max, getMax()) : max)));
  }

  return (
    <div
      role="separator"
      aria-orientation={vertical ? "horizontal" : "vertical"}
      aria-label={label}
      tabIndex={0}
      className={`rd-resize rd-resize-${side}`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={end}
      onPointerCancel={end}
      onDoubleClick={onReset}
      onKeyDown={onKeyDown}
    />
  );
}
