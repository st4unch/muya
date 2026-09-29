import { useState, useRef, useCallback } from "react";
import { GripHorizontal, X, Terminal as TerminalIcon } from "lucide-react";
import TerminalComponent from "./Terminal";
import type { TermTheme } from "./Terminal";

interface GridTerminal {
  key: string;
  name: string;
  cwd?: string;
  initialCommand?: string;
}

// Resize divider — drag to change panel split percentages
function ResizeDivider({
  direction,
  onResize,
}: {
  direction: "horizontal" | "vertical";
  onResize: (delta: number) => void;
}) {
  const dragging = useRef(false);
  const last = useRef(0);

  const onMouseDown = (e: React.MouseEvent) => {
    e.preventDefault();
    dragging.current = true;
    last.current = direction === "horizontal" ? e.clientX : e.clientY;

    const onMove = (ev: MouseEvent) => {
      if (!dragging.current) return;
      const current = direction === "horizontal" ? ev.clientX : ev.clientY;
      onResize(current - last.current);
      last.current = current;
    };
    const onUp = () => {
      dragging.current = false;
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  return (
    <div
      onMouseDown={onMouseDown}
      className={`shrink-0 flex items-center justify-center select-none z-10 ${
        direction === "horizontal"
          ? "w-2 cursor-col-resize hover:bg-indigo-500/20"
          : "h-2 cursor-row-resize hover:bg-indigo-500/20"
      }`}
    >
      <div
        className={`rounded-full bg-neutral-600 transition-colors ${
          direction === "horizontal" ? "w-0.5 h-8" : "h-0.5 w-8"
        }`}
      />
    </div>
  );
}

// One terminal cell with drag handle
function GridCell({
  terminal,
  onClose,
  theme,
  onDragStart,
  onDragOver,
  onDrop,
  isDragOver,
}: {
  terminal: GridTerminal;
  onClose: (key: string) => void;
  theme: TermTheme;
  onDragStart: (key: string) => void;
  onDragOver: (e: React.DragEvent) => void;
  onDrop: (key: string) => void;
  isDragOver: boolean;
}) {
  return (
    <div
      className={`flex flex-col h-full overflow-hidden bg-[var(--bg-terminal)] rounded border transition-colors ${
        isDragOver ? "border-indigo-500" : "border-neutral-700"
      }`}
      onDragOver={onDragOver}
      onDrop={() => onDrop(terminal.key)}
    >
      {/* Title bar — only this area is draggable */}
      <div
        draggable
        onDragStart={(e) => {
          e.dataTransfer.effectAllowed = "move";
          onDragStart(terminal.key);
        }}
        className="flex items-center gap-1.5 px-2 py-1 border-b border-neutral-700 bg-neutral-900 shrink-0 select-none cursor-grab active:cursor-grabbing"
      >
        <GripHorizontal className="h-3 w-3 text-neutral-500 shrink-0" />
        <TerminalIcon className="h-3 w-3 text-indigo-400 shrink-0" />
        <span className="text-[10px] font-mono text-neutral-300 truncate flex-1">{terminal.name}</span>
        <button
          type="button"
          onClick={() => onClose(terminal.key)}
          className="text-neutral-500 hover:text-rose-400 transition-colors cursor-pointer shrink-0"
        >
          <X className="h-3 w-3" />
        </button>
      </div>

      {/* Terminal surface */}
      <div className="flex-1 overflow-hidden p-1.5">
        <TerminalComponent
          cwd={terminal.cwd}
          initialCommand={terminal.initialCommand}
          theme={theme}
          active={true}
        />
      </div>
    </div>
  );
}

export default function TerminalGrid({
  terminals,
  gridKeys,
  onGridKeysChange,
  theme,
}: {
  terminals: GridTerminal[];
  gridKeys: string[];
  onGridKeysChange: (keys: string[]) => void;
  theme: TermTheme;
}) {
  const [dragFrom, setDragFrom] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState<string | null>(null);
  // Resize splits: [colSplit%, rowSplit%] — 50/50 defaults
  const [colSplit, setColSplit] = useState(50);
  const [rowSplit, setRowSplit] = useState(50);
  const containerRef = useRef<HTMLDivElement>(null);

  const byKey = Object.fromEntries(terminals.map((t) => [t.key, t]));
  const visible = gridKeys.map((k) => byKey[k]).filter(Boolean);
  const count = visible.length;

  const handleDragStart = (key: string) => setDragFrom(key);
  const handleDragOver = useCallback((e: React.DragEvent, key: string) => {
    e.preventDefault();
    setDragOver(key);
  }, []);
  const handleDrop = (toKey: string) => {
    if (!dragFrom || dragFrom === toKey) {
      setDragFrom(null);
      setDragOver(null);
      return;
    }
    const from = gridKeys.indexOf(dragFrom);
    const to = gridKeys.indexOf(toKey);
    if (from === -1 || to === -1) return;
    const next = [...gridKeys];
    [next[from], next[to]] = [next[to], next[from]];
    onGridKeysChange(next);
    setDragFrom(null);
    setDragOver(null);
  };

  const handleColResize = (delta: number) => {
    const w = containerRef.current?.offsetWidth ?? 800;
    const pct = (delta / w) * 100;
    setColSplit((v) => Math.max(20, Math.min(80, v + pct)));
  };
  const handleRowResize = (delta: number) => {
    const h = containerRef.current?.offsetHeight ?? 600;
    const pct = (delta / h) * 100;
    setRowSplit((v) => Math.max(20, Math.min(80, v + pct)));
  };

  const removeFromGrid = (key: string) => onGridKeysChange(gridKeys.filter((k) => k !== key));

  if (count === 0) return null;

  // 1 terminal — full area
  if (count === 1) {
    return (
      <div ref={containerRef} className="h-full p-2 bg-neutral-950">
        <GridCell
          terminal={visible[0]}
          onClose={removeFromGrid}
          theme={theme}
          onDragStart={handleDragStart}
          onDragOver={(e) => handleDragOver(e, visible[0].key)}
          onDrop={handleDrop}
          isDragOver={dragOver === visible[0].key}
        />
      </div>
    );
  }

  // 2 terminals — side by side
  if (count === 2) {
    return (
      <div ref={containerRef} className="h-full p-2 bg-neutral-950 flex gap-0">
        <div style={{ width: `${colSplit}%` }} className="min-w-0">
          <GridCell terminal={visible[0]} onClose={removeFromGrid} theme={theme}
            onDragStart={handleDragStart} onDragOver={(e) => handleDragOver(e, visible[0].key)}
            onDrop={handleDrop} isDragOver={dragOver === visible[0].key} />
        </div>
        <ResizeDivider direction="horizontal" onResize={handleColResize} />
        <div style={{ width: `${100 - colSplit}%` }} className="min-w-0">
          <GridCell terminal={visible[1]} onClose={removeFromGrid} theme={theme}
            onDragStart={handleDragStart} onDragOver={(e) => handleDragOver(e, visible[1].key)}
            onDrop={handleDrop} isDragOver={dragOver === visible[1].key} />
        </div>
      </div>
    );
  }

  // 3 or 4 terminals — 2×2 grid
  const top = visible.slice(0, 2);
  const bottom = visible.slice(2, 4);

  return (
    <div ref={containerRef} className="h-full p-2 bg-neutral-950 flex flex-col gap-0">
      {/* Top row */}
      <div style={{ height: `${rowSplit}%` }} className="flex gap-0 min-h-0">
        <div style={{ width: `${colSplit}%` }} className="min-w-0">
          <GridCell terminal={top[0]} onClose={removeFromGrid} theme={theme}
            onDragStart={handleDragStart} onDragOver={(e) => handleDragOver(e, top[0].key)}
            onDrop={handleDrop} isDragOver={dragOver === top[0].key} />
        </div>
        <ResizeDivider direction="horizontal" onResize={handleColResize} />
        <div style={{ width: `${100 - colSplit}%` }} className="min-w-0">
          <GridCell terminal={top[1]} onClose={removeFromGrid} theme={theme}
            onDragStart={handleDragStart} onDragOver={(e) => handleDragOver(e, top[1].key)}
            onDrop={handleDrop} isDragOver={dragOver === top[1].key} />
        </div>
      </div>

      <ResizeDivider direction="vertical" onResize={handleRowResize} />

      {/* Bottom row */}
      <div style={{ height: `${100 - rowSplit}%` }} className="flex gap-0 min-h-0">
        <div style={{ width: `${colSplit}%` }} className="min-w-0">
          {bottom[0] && (
            <GridCell terminal={bottom[0]} onClose={removeFromGrid} theme={theme}
              onDragStart={handleDragStart} onDragOver={(e) => handleDragOver(e, bottom[0].key)}
              onDrop={handleDrop} isDragOver={dragOver === bottom[0].key} />
          )}
        </div>
        {bottom[1] && <ResizeDivider direction="horizontal" onResize={handleColResize} />}
        <div style={{ width: `${100 - colSplit}%` }} className="min-w-0">
          {bottom[1] && (
            <GridCell terminal={bottom[1]} onClose={removeFromGrid} theme={theme}
              onDragStart={handleDragStart} onDragOver={(e) => handleDragOver(e, bottom[1].key)}
              onDrop={handleDrop} isDragOver={dragOver === bottom[1].key} />
          )}
        </div>
      </div>
    </div>
  );
}
