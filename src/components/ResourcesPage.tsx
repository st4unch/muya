import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  Puzzle,
  Bot,
  Plug,
  Zap,
  Search,
  FileText,
  ChevronRight,
  Loader2,
  Sparkles,
  ShoppingBag,
  Download,
  ExternalLink,
  Star,
} from "lucide-react";
import CreateWithClaudeModal from "./CreateWithClaudeModal";

// ── Types ─────────────────────────────────────────────────────────────────────

interface ClaudeSkill   { name: string; path: string }
interface ClaudeAgent   { name: string; path: string }
interface ClaudeHook    { name: string; path: string }
interface ClaudeMcp     { name: string; command: string; description: string }
interface ClaudeResources {
  skills: ClaudeSkill[];
  agents: ClaudeAgent[];
  hooks:  ClaudeHook[];
  mcps:   ClaudeMcp[];
}

interface MarketSkill {
  name: string;
  description: string;
  stars: string;
  author: string;
  githubUrl: string;
}
interface MarketMcp {
  name: string;
  description: string;
  command: string;
  args: string[];
  source: string;
}
interface MarketResult {
  items: MarketMcp[];
  openBrowser: boolean;
}

type LocalTab      = "skills" | "agents" | "hooks" | "mcps";
type MarketSubTab  = "skills" | "mcps";
type MainTab       = LocalTab | "marketplace";

interface OpenTerminalSpec {
  key: string;
  name: string;
  kind: "terminal";
  cwd?: string;
  initialCommand?: string;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const LOCAL_TABS: { id: LocalTab; label: string; icon: React.ReactNode }[] = [
  { id: "skills", label: "Skills",  icon: <Puzzle className="w-4 h-4" /> },
  { id: "agents", label: "Agents",  icon: <Bot    className="w-4 h-4" /> },
  { id: "hooks",  label: "Hooks",   icon: <Zap    className="w-4 h-4" /> },
  { id: "mcps",   label: "MCPs",    icon: <Plug   className="w-4 h-4" /> },
];

// ── Shared styles ─────────────────────────────────────────────────────────────

const tabActive   = "bg-indigo-50 dark:bg-indigo-950/40 text-indigo-700 dark:text-indigo-300 font-bold border border-indigo-200 dark:border-indigo-800";
const tabInactive = "text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 hover:bg-neutral-100 dark:hover:bg-neutral-800 border border-transparent";
const badgeActive   = "bg-indigo-100 dark:bg-indigo-800/40 text-indigo-700 dark:text-indigo-300";
const badgeInactive = "bg-neutral-100 dark:bg-neutral-800 text-neutral-500 dark:text-neutral-400";
const rowActive   = "bg-indigo-50 dark:bg-indigo-950/30 text-indigo-700 dark:text-indigo-300";
const rowInactive = "text-neutral-800 dark:text-neutral-200 hover:bg-neutral-50 dark:hover:bg-neutral-800";

// ── Component ─────────────────────────────────────────────────────────────────

export default function ResourcesPage({
  onOpenTerminal,
}: {
  onOpenTerminal: (spec: OpenTerminalSpec) => void;
}) {
  // ── Local resources ──────────────────────────────────────────────────────
  const [resources, setResources]     = useState<ClaudeResources | null>(null);
  const [resLoading, setResLoading]   = useState(true);
  const [resError, setResError]       = useState<string | null>(null);

  // ── Navigation ───────────────────────────────────────────────────────────
  const [mainTab, setMainTab]           = useState<MainTab>("skills");
  const [marketSubTab, setMarketSubTab] = useState<MarketSubTab>("skills");
  const [query, setQuery]               = useState("");

  // ── File viewer ──────────────────────────────────────────────────────────
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [fileContent, setFileContent]   = useState<string | null>(null);
  const [fileLoading, setFileLoading]   = useState(false);
  const [fileError, setFileError]       = useState<string | null>(null);

  // ── Marketplace ──────────────────────────────────────────────────────────
  const [marketSkills, setMarketSkills]   = useState<MarketSkill[]>([]);
  const [marketMcps, setMarketMcps]       = useState<MarketMcp[]>([]);
  const [marketOpenBrowser, setMarketOpenBrowser] = useState(false);
  const [marketLoading, setMarketLoading] = useState(false);
  const [marketError, setMarketError]     = useState<string | null>(null);
  const [installingKey, setInstallingKey] = useState<string | null>(null);
  const [selectedMarket, setSelectedMarket] = useState<MarketSkill | MarketMcp | null>(null);

  // ── Create modal ─────────────────────────────────────────────────────────
  const [createOpen, setCreateOpen] = useState(false);

  // ── Search debounce ref ──────────────────────────────────────────────────
  const searchTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // ── Load local resources once ────────────────────────────────────────────
  useEffect(() => {
    invoke<ClaudeResources>("list_claude_resources")
      .then(setResources)
      .catch((e) => setResError(String(e)))
      .finally(() => setResLoading(false));
  }, []);

  // ── Fetch marketplace when tab or query changes ───────────────────────────
  const fetchMarket = useCallback(async (q: string) => {
    setMarketLoading(true);
    setMarketError(null);
    try {
      if (marketSubTab === "skills") {
        const skills = await invoke<MarketSkill[]>("fetch_skill_marketplace", { query: q });
        setMarketSkills(skills);
      } else {
        const result = await invoke<MarketResult>("fetch_mcp_marketplace", { query: q });
        setMarketMcps(result.items);
        setMarketOpenBrowser(result.openBrowser);
      }
    } catch (e) {
      setMarketError(String(e));
    } finally {
      setMarketLoading(false);
    }
  }, [marketSubTab]);

  useEffect(() => {
    if (mainTab !== "marketplace") return;
    setSelectedMarket(null);
    if (searchTimer.current) clearTimeout(searchTimer.current);
    searchTimer.current = setTimeout(() => fetchMarket(query), 400);
    return () => { if (searchTimer.current) clearTimeout(searchTimer.current); };
  }, [mainTab, marketSubTab, query, fetchMarket]);

  // ── File open helpers ────────────────────────────────────────────────────
  const openFile = async (path: string) => {
    setSelectedPath(path);
    setFileContent(null);
    setFileError(null);
    setFileLoading(true);
    try {
      setFileContent(await invoke<string>("read_file", { path }));
    } catch {
      setFileError("Dosya okunamadı.");
    } finally {
      setFileLoading(false);
    }
  };

  const openSkill = async (skill: ClaudeSkill) => {
    const candidates = [
      `${skill.path}/README.md`,
      `${skill.path}/skill.md`,
      `${skill.path}/${skill.name}.md`,
    ];
    setSelectedPath(skill.path);
    setFileContent(null);
    setFileError(null);
    setFileLoading(true);
    for (const c of candidates) {
      try {
        setFileContent(await invoke<string>("read_file", { path: c }));
        setSelectedPath(c);
        setFileLoading(false);
        return;
      } catch { /* try next */ }
    }
    try {
      const entries = await invoke<{ name: string; path: string; isDirectory: boolean }[]>(
        "list_dir", { path: skill.path }
      );
      const firstMd = entries.find((e) => !e.isDirectory && e.name.endsWith(".md"));
      if (firstMd) {
        setFileContent(await invoke<string>("read_file", { path: firstMd.path }));
        setSelectedPath(firstMd.path);
      } else {
        setFileError("Okunabilir içerik bulunamadı.");
      }
    } catch {
      setFileError("Dosya okunamadı.");
    }
    setFileLoading(false);
  };

  // ── Install helpers ──────────────────────────────────────────────────────
  const installSkill = async (skill: MarketSkill) => {
    if (!skill.githubUrl) return;
    setInstallingKey(skill.name);
    try {
      await invoke("install_skill", { name: skill.name, githubUrl: skill.githubUrl });
      // Refresh local list
      const updated = await invoke<ClaudeResources>("list_claude_resources");
      setResources(updated);
      alert(`✓ ${skill.name} ~/.claude/skills/ klasörüne yüklendi.`);
    } catch (e) {
      alert(`Hata: ${e}`);
    } finally {
      setInstallingKey(null);
    }
  };

  const installMcp = async (mcp: MarketMcp) => {
    setInstallingKey(mcp.name);
    try {
      await invoke("install_mcp", { name: mcp.name, command: mcp.command, args: mcp.args });
      const updated = await invoke<ClaudeResources>("list_claude_resources");
      setResources(updated);
      alert(`✓ ${mcp.name} ~/.claude/.mcp.json dosyasına eklendi.`);
    } catch (e) {
      alert(`Hata: ${e}`);
    } finally {
      setInstallingKey(null);
    }
  };

  // ── Filtered local lists ─────────────────────────────────────────────────
  const q = query.toLowerCase();
  const filteredSkills = resources?.skills.filter((s) => s.name.toLowerCase().includes(q)) ?? [];
  const filteredAgents = resources?.agents.filter((a) => a.name.toLowerCase().includes(q)) ?? [];
  const filteredHooks  = resources?.hooks.filter((h)  => h.name.toLowerCase().includes(q)) ?? [];
  const filteredMcps   = resources?.mcps.filter((m) =>
    m.name.toLowerCase().includes(q) || m.description.toLowerCase().includes(q)
  ) ?? [];

  const localCounts: Record<LocalTab, number> = {
    skills: filteredSkills.length,
    agents: filteredAgents.length,
    hooks:  filteredHooks.length,
    mcps:   filteredMcps.length,
  };

  const selectedFileName = selectedPath ? selectedPath.split("/").pop() : null;
  const isMarketplace = mainTab === "marketplace";

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <>
      <div className="flex flex-col h-full overflow-hidden bg-white dark:bg-neutral-900">
        {/* ── Top bar ───────────────────────────────────────────────────── */}
        <div className="flex items-center gap-3 px-4 py-3 border-b border-neutral-200 dark:border-neutral-700 shrink-0">
          <h2 className="text-sm font-semibold text-neutral-800 dark:text-neutral-200 shrink-0 mr-1">
            Claude Resources
          </h2>
          <div className="relative flex-1 max-w-xs">
            <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-neutral-400 dark:text-neutral-500" />
            <input
              className="w-full pl-8 pr-3 py-1.5 text-xs rounded border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-800 text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 dark:placeholder:text-neutral-500 focus:outline-none focus:ring-1 focus:ring-indigo-400"
              placeholder={isMarketplace ? "Market'te ara…" : "Ara…"}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </div>
          <div className="ml-auto shrink-0">
            <button
              onClick={() => setCreateOpen(true)}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white transition-colors cursor-pointer"
            >
              <Sparkles className="w-3.5 h-3.5" />
              Create with Claude
            </button>
          </div>
        </div>

        {/* ── Tab bar ───────────────────────────────────────────────────── */}
        <div className="flex items-center gap-1 px-4 py-2 border-b border-neutral-200 dark:border-neutral-700 shrink-0 flex-wrap">
          {/* Local tabs */}
          {LOCAL_TABS.map((t) => (
            <button
              key={t.id}
              onClick={() => { setMainTab(t.id); setSelectedPath(null); }}
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded text-xs transition-colors cursor-pointer ${
                mainTab === t.id ? tabActive : tabInactive
              }`}
            >
              {t.icon}
              {t.label}
              {mainTab !== "marketplace" && (
                <span className={`ml-1 px-1.5 py-0.5 rounded-full text-[10px] ${
                  mainTab === t.id ? badgeActive : badgeInactive
                }`}>
                  {localCounts[t.id as LocalTab]}
                </span>
              )}
            </button>
          ))}

          {/* Separator */}
          <div className="h-4 w-px bg-neutral-200 dark:bg-neutral-700 mx-1" />

          {/* Marketplace tab */}
          <button
            onClick={() => { setMainTab("marketplace"); setSelectedPath(null); setSelectedMarket(null); }}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded text-xs transition-colors cursor-pointer ${
              mainTab === "marketplace" ? tabActive : tabInactive
            }`}
          >
            <ShoppingBag className="w-4 h-4" />
            Marketplace
          </button>

          {/* Marketplace sub-tabs */}
          {isMarketplace && (
            <div className="flex items-center gap-1 ml-1">
              {(["skills", "mcps"] as MarketSubTab[]).map((st) => (
                <button
                  key={st}
                  onClick={() => { setMarketSubTab(st); setSelectedMarket(null); }}
                  className={`px-2.5 py-1 rounded text-[11px] transition-colors cursor-pointer ${
                    marketSubTab === st
                      ? "bg-neutral-200 dark:bg-neutral-700 text-neutral-800 dark:text-neutral-200 font-medium"
                      : "text-neutral-500 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800"
                  }`}
                >
                  {st === "skills" ? "Skills" : "MCPs"}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* ── Body ──────────────────────────────────────────────────────── */}
        <div className="flex flex-1 overflow-hidden">
          {/* Left list */}
          <div className="w-72 shrink-0 border-r border-neutral-200 dark:border-neutral-700 overflow-y-auto bg-neutral-50/50 dark:bg-neutral-900">

            {/* ── LOCAL view ── */}
            {!isMarketplace && (
              <>
                {resLoading && (
                  <div className="flex items-center justify-center py-12 text-neutral-400">
                    <Loader2 className="w-4 h-4 animate-spin mr-2" />
                    <span className="text-xs">Yükleniyor…</span>
                  </div>
                )}
                {resError && <div className="px-4 py-4 text-xs text-rose-600">{resError}</div>}

                {/* Skills list */}
                {!resLoading && mainTab === "skills" && (
                  <ul>
                    {filteredSkills.length === 0 && <EmptyRow />}
                    {filteredSkills.map((s) => (
                      <li key={s.path}>
                        <button
                          onClick={() => openSkill(s)}
                          className={`w-full flex items-center gap-2 px-4 py-2.5 text-left transition-colors ${
                            selectedPath?.startsWith(s.path) ? rowActive : rowInactive
                          }`}
                        >
                          <Puzzle className="w-3.5 h-3.5 shrink-0 text-purple-500 dark:text-purple-400" />
                          <span className="text-xs truncate">{s.name}</span>
                          <ChevronRight className="w-3 h-3 ml-auto shrink-0 text-neutral-400" />
                        </button>
                      </li>
                    ))}
                  </ul>
                )}

                {/* Agents list */}
                {!resLoading && mainTab === "agents" && (
                  <ul>
                    {filteredAgents.length === 0 && <EmptyRow />}
                    {filteredAgents.map((a) => (
                      <li key={a.path}>
                        <button
                          onClick={() => openFile(a.path)}
                          className={`w-full flex items-center gap-2 px-4 py-2.5 text-left transition-colors ${
                            selectedPath === a.path ? rowActive : rowInactive
                          }`}
                        >
                          <Bot className="w-3.5 h-3.5 shrink-0 text-emerald-600 dark:text-emerald-400" />
                          <span className="text-xs truncate">{a.name}</span>
                          <ChevronRight className="w-3 h-3 ml-auto shrink-0 text-neutral-400" />
                        </button>
                      </li>
                    ))}
                  </ul>
                )}

                {/* Hooks list */}
                {!resLoading && mainTab === "hooks" && (
                  <ul>
                    {filteredHooks.length === 0 && <EmptyRow />}
                    {filteredHooks.map((h) => (
                      <li key={h.path}>
                        <button
                          onClick={() => openFile(h.path)}
                          className={`w-full flex items-center gap-2 px-4 py-2.5 text-left transition-colors ${
                            selectedPath === h.path ? rowActive : rowInactive
                          }`}
                        >
                          <Zap className="w-3.5 h-3.5 shrink-0 text-amber-500 dark:text-yellow-400" />
                          <span className="text-xs truncate">{h.name}</span>
                          <ChevronRight className="w-3 h-3 ml-auto shrink-0 text-neutral-400" />
                        </button>
                      </li>
                    ))}
                  </ul>
                )}

                {/* MCPs list */}
                {!resLoading && mainTab === "mcps" && (
                  <ul>
                    {filteredMcps.length === 0 && <EmptyRow />}
                    {filteredMcps.map((m) => (
                      <li key={m.name}>
                        <button
                          onClick={() => { setSelectedPath(m.name); setFileContent(null); setFileError(null); }}
                          className={`w-full flex flex-col gap-0.5 px-4 py-2.5 text-left border-b border-neutral-100 dark:border-neutral-800 transition-colors ${
                            selectedPath === m.name ? rowActive : rowInactive
                          }`}
                        >
                          <div className="flex items-center gap-2">
                            <Plug className="w-3.5 h-3.5 shrink-0 text-cyan-600 dark:text-cyan-400" />
                            <span className="text-xs font-medium truncate">{m.name}</span>
                          </div>
                          {m.description && (
                            <p className="text-[11px] text-neutral-500 dark:text-neutral-400 truncate pl-5">{m.description}</p>
                          )}
                          <p className="text-[10px] text-neutral-400 dark:text-neutral-500 truncate pl-5 font-mono">{m.command}</p>
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </>
            )}

            {/* ── MARKETPLACE view ── */}
            {isMarketplace && (
              <>
                {marketLoading && (
                  <div className="flex items-center justify-center py-12 text-neutral-400">
                    <Loader2 className="w-4 h-4 animate-spin mr-2" />
                    <span className="text-xs">Yükleniyor…</span>
                  </div>
                )}
                {marketError && (
                  <div className="px-4 py-4 text-xs text-rose-600 dark:text-rose-400">{marketError}</div>
                )}

                {/* Skills market list */}
                {!marketLoading && marketSubTab === "skills" && (
                  <ul>
                    {marketSkills.length === 0 && !marketLoading && (
                      <li className="px-4 py-6 text-xs text-center text-neutral-400">
                        Sonuç bulunamadı
                      </li>
                    )}
                    {marketSkills.map((s) => (
                      <li key={s.name}>
                        <button
                          onClick={() => setSelectedMarket(s)}
                          className={`w-full flex flex-col gap-0.5 px-4 py-3 text-left border-b border-neutral-100 dark:border-neutral-800 transition-colors ${
                            (selectedMarket as MarketSkill)?.name === s.name ? rowActive : rowInactive
                          }`}
                        >
                          <div className="flex items-center gap-2">
                            <Puzzle className="w-3.5 h-3.5 shrink-0 text-purple-500 dark:text-purple-400" />
                            <span className="text-xs font-medium truncate flex-1">{s.name}</span>
                            <button
                              onClick={(e) => { e.stopPropagation(); installSkill(s); }}
                              disabled={installingKey === s.name || !s.githubUrl}
                              className="shrink-0 flex items-center gap-1 px-2 py-0.5 text-[10px] rounded border border-neutral-200 dark:border-neutral-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 hover:border-indigo-300 dark:hover:border-indigo-700 hover:text-indigo-700 dark:hover:text-indigo-300 disabled:opacity-40 text-neutral-500 dark:text-neutral-400 transition-colors"
                            >
                              {installingKey === s.name ? (
                                <Loader2 className="w-3 h-3 animate-spin" />
                              ) : (
                                <Download className="w-3 h-3" />
                              )}
                              Yükle
                            </button>
                          </div>
                          {s.stars && s.stars !== "—" && (
                            <div className="flex items-center gap-1 pl-5 text-[10px] text-neutral-400">
                              <Star className="w-2.5 h-2.5" />
                              {s.stars}
                              {s.author && <span className="ml-1">· @{s.author}</span>}
                            </div>
                          )}
                          {s.description && (
                            <p className="text-[11px] text-neutral-500 dark:text-neutral-400 truncate pl-5">{s.description}</p>
                          )}
                        </button>
                      </li>
                    ))}
                  </ul>
                )}

                {/* MCPs market list */}
                {!marketLoading && marketSubTab === "mcps" && (
                  <>
                    {marketOpenBrowser && (
                      <div className="px-4 py-3 bg-amber-50 dark:bg-amber-950/30 border-b border-amber-100 dark:border-amber-900">
                        <p className="text-[11px] text-amber-700 dark:text-amber-400 mb-2">
                          mcpmarket.com API'sine erişilemedi.
                        </p>
                        <button
                          onClick={() => openUrl("https://mcpmarket.com")}
                          className="flex items-center gap-1.5 text-[11px] text-indigo-600 dark:text-indigo-400 hover:underline"
                        >
                          <ExternalLink className="w-3 h-3" />
                          Tarayıcıda aç
                        </button>
                      </div>
                    )}
                    <ul>
                      {marketMcps.length === 0 && !marketOpenBrowser && !marketLoading && (
                        <li className="px-4 py-6 text-xs text-center text-neutral-400">
                          Sonuç bulunamadı
                        </li>
                      )}
                      {marketMcps.map((m) => (
                        <li key={m.name}>
                          <button
                            onClick={() => setSelectedMarket(m)}
                            className={`w-full flex flex-col gap-0.5 px-4 py-3 text-left border-b border-neutral-100 dark:border-neutral-800 transition-colors ${
                              (selectedMarket as MarketMcp)?.name === m.name ? rowActive : rowInactive
                            }`}
                          >
                            <div className="flex items-center gap-2">
                              <Plug className="w-3.5 h-3.5 shrink-0 text-cyan-600 dark:text-cyan-400" />
                              <span className="text-xs font-medium truncate flex-1">{m.name}</span>
                              <button
                                onClick={(e) => { e.stopPropagation(); installMcp(m); }}
                                disabled={installingKey === m.name || !m.command}
                                className="shrink-0 flex items-center gap-1 px-2 py-0.5 text-[10px] rounded border border-neutral-200 dark:border-neutral-700 hover:bg-indigo-50 dark:hover:bg-indigo-950/30 hover:border-indigo-300 hover:text-indigo-700 dark:hover:text-indigo-300 disabled:opacity-40 text-neutral-500 dark:text-neutral-400 transition-colors"
                              >
                                {installingKey === m.name ? (
                                  <Loader2 className="w-3 h-3 animate-spin" />
                                ) : (
                                  <Download className="w-3 h-3" />
                                )}
                                Yükle
                              </button>
                            </div>
                            {m.description && (
                              <p className="text-[11px] text-neutral-500 dark:text-neutral-400 truncate pl-5">{m.description}</p>
                            )}
                          </button>
                        </li>
                      ))}
                    </ul>
                  </>
                )}
              </>
            )}
          </div>

          {/* Right content / detail panel */}
          <div className="flex-1 overflow-hidden flex flex-col bg-white dark:bg-neutral-900">

            {/* ── Empty state ── */}
            {!selectedPath && !selectedMarket && (
              <div className="flex flex-col items-center justify-center h-full text-neutral-400 dark:text-neutral-600 gap-2">
                <FileText className="w-8 h-8 opacity-40" />
                <span className="text-xs">Bir öğe seçin</span>
              </div>
            )}

            {/* ── Local MCP detail ── */}
            {selectedPath && mainTab === "mcps" && !isMarketplace && (
              <div className="p-5">
                {filteredMcps.filter((m) => m.name === selectedPath).map((m) => (
                  <div key={m.name} className="space-y-3">
                    <div className="flex items-center gap-2">
                      <Plug className="w-5 h-5 text-cyan-600 dark:text-cyan-400" />
                      <span className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">{m.name}</span>
                    </div>
                    {m.description && <p className="text-xs text-neutral-600 dark:text-neutral-400">{m.description}</p>}
                    <div className="rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-800 p-3">
                      <p className="text-[10px] text-neutral-500 uppercase tracking-wider mb-1">Command / URL</p>
                      <p className="text-xs font-mono text-neutral-800 dark:text-neutral-200 break-all">{m.command}</p>
                    </div>
                  </div>
                ))}
              </div>
            )}

            {/* ── File content panel (skills/agents/hooks) ── */}
            {selectedPath && mainTab !== "mcps" && !isMarketplace && (
              <>
                <div className="flex items-center gap-2 px-4 py-2 border-b border-neutral-200 dark:border-neutral-700 shrink-0 bg-neutral-50 dark:bg-neutral-800/50">
                  <FileText className="w-3.5 h-3.5 text-neutral-400" />
                  <span className="text-xs text-neutral-500 font-mono truncate">{selectedFileName}</span>
                </div>
                <div className="flex-1 overflow-y-auto p-4">
                  {fileLoading && (
                    <div className="flex items-center gap-2 text-neutral-400">
                      <Loader2 className="w-3.5 h-3.5 animate-spin" />
                      <span className="text-xs">Yükleniyor…</span>
                    </div>
                  )}
                  {fileError && <p className="text-xs text-rose-600">{fileError}</p>}
                  {fileContent !== null && !fileLoading && (
                    <pre className="text-xs font-mono text-neutral-800 dark:text-neutral-200 whitespace-pre-wrap leading-relaxed">
                      {fileContent}
                    </pre>
                  )}
                </div>
              </>
            )}

            {/* ── Marketplace detail: Skill ── */}
            {isMarketplace && selectedMarket && marketSubTab === "skills" && (
              <MarketSkillDetail
                skill={selectedMarket as MarketSkill}
                installing={installingKey === (selectedMarket as MarketSkill).name}
                onInstall={() => installSkill(selectedMarket as MarketSkill)}
              />
            )}

            {/* ── Marketplace detail: MCP ── */}
            {isMarketplace && selectedMarket && marketSubTab === "mcps" && (
              <MarketMcpDetail
                mcp={selectedMarket as MarketMcp}
                installing={installingKey === (selectedMarket as MarketMcp).name}
                onInstall={() => installMcp(selectedMarket as MarketMcp)}
              />
            )}
          </div>
        </div>
      </div>

      {/* Create with Claude modal */}
      <CreateWithClaudeModal
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        onOpenTerminal={(spec) => {
          onOpenTerminal(spec);
        }}
      />
    </>
  );
}

// ── Sub-components ────────────────────────────────────────────────────────────

function EmptyRow() {
  return (
    <li className="px-4 py-3 text-xs text-neutral-400 dark:text-neutral-500">Sonuç yok</li>
  );
}

function MarketSkillDetail({
  skill,
  installing,
  onInstall,
}: {
  skill: MarketSkill;
  installing: boolean;
  onInstall: () => void;
}) {
  return (
    <div className="p-5 flex flex-col gap-4">
      <div className="flex items-start gap-3">
        <Puzzle className="w-5 h-5 text-purple-500 dark:text-purple-400 mt-0.5 shrink-0" />
        <div>
          <h3 className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">{skill.name}</h3>
          {skill.author && (
            <p className="text-xs text-neutral-500 dark:text-neutral-400">@{skill.author} · skillsmp.com</p>
          )}
        </div>
        {skill.stars && skill.stars !== "—" && (
          <div className="ml-auto flex items-center gap-1 text-xs text-neutral-500">
            <Star className="w-3 h-3" />
            {skill.stars}
          </div>
        )}
      </div>

      {skill.description && (
        <p className="text-xs text-neutral-700 dark:text-neutral-300 leading-relaxed">{skill.description}</p>
      )}

      {skill.githubUrl && (
        <div className="rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-800 p-3">
          <p className="text-[10px] text-neutral-500 uppercase tracking-wider mb-1">GitHub</p>
          <button
            onClick={() => openUrl(skill.githubUrl)}
            className="flex items-center gap-1.5 text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
          >
            <ExternalLink className="w-3 h-3" />
            {skill.githubUrl}
          </button>
        </div>
      )}

      <button
        onClick={onInstall}
        disabled={installing || !skill.githubUrl}
        className="flex items-center justify-center gap-2 w-full py-2.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300 dark:disabled:bg-indigo-800 text-white text-xs font-medium transition-colors cursor-pointer disabled:cursor-not-allowed"
      >
        {installing ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Download className="w-3.5 h-3.5" />}
        {installing ? "Yükleniyor…" : "~/.claude/skills/ klasörüne yükle"}
      </button>
    </div>
  );
}

function MarketMcpDetail({
  mcp,
  installing,
  onInstall,
}: {
  mcp: MarketMcp;
  installing: boolean;
  onInstall: () => void;
}) {
  return (
    <div className="p-5 flex flex-col gap-4">
      <div className="flex items-start gap-3">
        <Plug className="w-5 h-5 text-cyan-600 dark:text-cyan-400 mt-0.5 shrink-0" />
        <div>
          <h3 className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">{mcp.name}</h3>
          {mcp.source && (
            <p className="text-xs text-neutral-500 dark:text-neutral-400">{mcp.source}</p>
          )}
        </div>
      </div>

      {mcp.description && (
        <p className="text-xs text-neutral-700 dark:text-neutral-300 leading-relaxed">{mcp.description}</p>
      )}

      {mcp.command && (
        <div className="rounded border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-800 p-3 space-y-2">
          <p className="text-[10px] text-neutral-500 uppercase tracking-wider">Command</p>
          <p className="text-xs font-mono text-neutral-800 dark:text-neutral-200 break-all">{mcp.command}</p>
          {mcp.args.length > 0 && (
            <>
              <p className="text-[10px] text-neutral-500 uppercase tracking-wider">Args</p>
              <p className="text-xs font-mono text-neutral-800 dark:text-neutral-200">{mcp.args.join(" ")}</p>
            </>
          )}
        </div>
      )}

      <button
        onClick={onInstall}
        disabled={installing || !mcp.command}
        className="flex items-center justify-center gap-2 w-full py-2.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300 dark:disabled:bg-indigo-800 text-white text-xs font-medium transition-colors cursor-pointer disabled:cursor-not-allowed"
      >
        {installing ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Download className="w-3.5 h-3.5" />}
        {installing ? "Ekleniyor…" : "~/.claude/.mcp.json dosyasına ekle"}
      </button>
    </div>
  );
}
