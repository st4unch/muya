import { useState, useEffect } from "react";
import { Clock, X, Plus, Trash2, CalendarClock, Terminal, CheckSquare, Square } from "lucide-react";

export interface ScheduledPrompt {
  id: string;
  prompt: string;
  terminalKeys: string[];
  scheduledAt: number; // epoch ms
  fired: boolean;
}

interface TerminalOption {
  key: string;
  name: string;
}


function pad(n: number) { return String(n).padStart(2, "0"); }

function defaultTime() {
  const d = new Date(Date.now() + 5 * 60_000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function defaultDate() {
  const d = new Date();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function combineToEpoch(dateStr: string, timeStr: string): number {
  return new Date(`${dateStr}T${timeStr}`).getTime();
}

export default function ScheduledPromptModal({
  open,
  onClose,
  terminals,
  scheduled,
  onAdd,
  onCancel,
}: {
  open: boolean;
  onClose: () => void;
  terminals: TerminalOption[];
  scheduled: ScheduledPrompt[];
  onAdd: (p: Omit<ScheduledPrompt, "id" | "fired">) => void;
  onCancel: (id: string) => void;
}) {
  const [prompt, setPrompt] = useState("");
  const [selectedKeys, setSelectedKeys] = useState<string[]>([]);
  const [timeVal, setTimeVal] = useState(defaultTime);
  const [dateVal, setDateVal] = useState(defaultDate);
  const [flashKey, setFlashKey] = useState<string | null>(null);

  // Refresh default time/date each time the modal opens so the default is never stale.
  useEffect(() => {
    if (open) {
      setTimeVal(defaultTime());
      setDateVal(defaultDate());
    }
  }, [open]);

  if (!open) return null;

  const toggleKey = (key: string) => {
    setSelectedKeys(prev =>
      prev.includes(key) ? prev.filter(k => k !== key) : [...prev, key]
    );
    setFlashKey(key);
    setTimeout(() => setFlashKey(null), 350);
  };

  const handleAdd = () => {
    if (!prompt.trim() || selectedKeys.length === 0) return;
    const scheduledAt = combineToEpoch(dateVal, timeVal);
    if (isNaN(scheduledAt) || scheduledAt <= Date.now()) return;
    onAdd({ prompt: prompt.trim(), terminalKeys: selectedKeys, scheduledAt });
    setPrompt("");
    setSelectedKeys([]);
    setTimeVal(defaultTime());
    setDateVal(defaultDate());
  };

  const pending = scheduled.filter(p => !p.fired);
  const recent = scheduled.filter(p => p.fired).slice(-5);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm" onClick={onClose}>
      <div
        className="bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-700 rounded-xl shadow-2xl w-[480px] max-h-[85vh] flex flex-col overflow-hidden"
        onClick={e => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-200 dark:border-neutral-700 shrink-0">
          <div className="flex items-center gap-2">
            <CalendarClock className="h-4 w-4 text-indigo-500 dark:text-indigo-400" />
            <span className="text-sm font-display font-bold text-neutral-800 dark:text-neutral-200">Scheduled Prompt</span>
          </div>
          <button type="button" onClick={onClose} className="text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 cursor-pointer">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Prompt */}
          <div>
            <label className="block text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400 mb-1.5">Prompt</label>
            <textarea
              value={prompt}
              onChange={e => setPrompt(e.target.value)}
              placeholder="Claude'a gönderilecek komutu yaz…"
              rows={3}
              className="w-full px-3 py-2 text-xs font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 placeholder-neutral-400 dark:placeholder-neutral-600 focus:outline-none focus:border-indigo-400 dark:focus:border-indigo-600 resize-none"
            />
          </div>

          {/* Terminal selector */}
          <div>
            <label className="block text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400 mb-1.5">
              Terminaller ({selectedKeys.length} seçili)
            </label>
            {terminals.length === 0 ? (
              <p className="text-[11px] font-mono text-neutral-400 dark:text-neutral-500">Açık terminal yok.</p>
            ) : (
              <div className="space-y-1">
                {terminals.map(t => {
                  const sel = selectedKeys.includes(t.key);
                  const flashing = flashKey === t.key;
                  return (
                    <button
                      key={t.key}
                      type="button"
                      onClick={() => toggleKey(t.key)}
                      style={{
                        transition: "background-color 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease",
                        boxShadow: flashing ? "0 0 0 2px #6366f1" : undefined,
                      }}
                      className={`w-full flex items-center gap-2 px-2.5 py-1.5 rounded border text-left cursor-pointer ${
                        sel
                          ? "border-indigo-300 dark:border-indigo-700 bg-indigo-50 dark:bg-indigo-950/30 text-indigo-800 dark:text-indigo-200"
                          : "border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-neutral-700 dark:text-neutral-300 hover:bg-neutral-50 dark:hover:bg-neutral-800"
                      }`}
                    >
                      {sel
                        ? <CheckSquare className="h-3.5 w-3.5 shrink-0 text-indigo-500" />
                        : <Square className="h-3.5 w-3.5 shrink-0 text-neutral-400" />
                      }
                      <Terminal className="h-3 w-3 shrink-0 text-indigo-400 dark:text-indigo-500" />
                      <span className="text-[11px] font-mono truncate">{t.name}</span>
                    </button>
                  );
                })}
              </div>
            )}
          </div>

          {/* Time + Date pickers */}
          <div>
            <label className="block text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400 mb-1.5">Zaman</label>
            <input
              type="time"
              step="1"
              value={timeVal}
              onChange={e => setTimeVal(e.target.value)}
              className="w-full px-3 py-2 text-sm font-mono tracking-widest rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-indigo-400 dark:focus:border-indigo-600 mb-1.5"
            />
            <input
              type="date"
              value={dateVal}
              onChange={e => setDateVal(e.target.value)}
              className="w-full px-3 py-1.5 text-xs font-mono rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-950 text-neutral-800 dark:text-neutral-200 focus:outline-none focus:border-indigo-400 dark:focus:border-indigo-600"
            />
          </div>

          {/* Add button */}
          <button
            type="button"
            onClick={handleAdd}
            disabled={!prompt.trim() || selectedKeys.length === 0}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 disabled:bg-neutral-200 dark:disabled:bg-neutral-800 text-white disabled:text-neutral-400 dark:disabled:text-neutral-600 text-xs font-mono font-bold transition-colors cursor-pointer disabled:cursor-not-allowed"
          >
            <Plus className="h-3.5 w-3.5" /> Schedule
          </button>

          {/* Pending list */}
          {pending.length > 0 && (
            <div>
              <label className="block text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400 mb-1.5">
                Bekleyen ({pending.length})
              </label>
              <div className="space-y-1.5">
                {pending.map(p => (
                  <div key={p.id} className="flex items-start gap-2 px-2.5 py-2 rounded border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/20">
                    <Clock className="h-3 w-3 text-amber-500 shrink-0 mt-0.5" />
                    <div className="flex-1 min-w-0">
                      <p className="text-[11px] font-mono text-neutral-800 dark:text-neutral-200 truncate">{p.prompt}</p>
                      <p className="text-[9px] font-mono text-neutral-500 dark:text-neutral-400 mt-0.5">
                        {new Date(p.scheduledAt).toLocaleString()} · {p.terminalKeys.length} terminal
                      </p>
                    </div>
                    <button type="button" onClick={() => onCancel(p.id)} className="text-neutral-400 hover:text-rose-500 cursor-pointer shrink-0">
                      <Trash2 className="h-3 w-3" />
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Recent fired */}
          {recent.length > 0 && (
            <div>
              <label className="block text-[10px] font-mono font-bold uppercase text-neutral-500 dark:text-neutral-400 mb-1.5">
                Son Gönderilen
              </label>
              <div className="space-y-1">
                {recent.map(p => (
                  <div key={p.id} className="flex items-center gap-2 px-2.5 py-1.5 rounded border border-neutral-100 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-950 opacity-60">
                    <CheckSquare className="h-3 w-3 text-emerald-500 shrink-0" />
                    <span className="text-[10px] font-mono text-neutral-600 dark:text-neutral-400 truncate flex-1">{p.prompt}</span>
                    <span className="text-[9px] font-mono text-neutral-400 shrink-0">{new Date(p.scheduledAt).toLocaleTimeString()}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
