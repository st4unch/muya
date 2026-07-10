import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { X, Sparkles, Puzzle, Bot, Zap, Plug } from "lucide-react";

type ResourceType = "skill" | "agent" | "hook" | "mcp";

interface OpenTerminalSpec {
  key: string;
  name: string;
  kind: "terminal";
  cwd?: string;
  initialCommand?: string;
}

const WRAPPER_PROMPTS: Record<ResourceType, string> = {
  skill: `You are a Claude Code skill author. Create a complete skill definition at ~/.claude/skills/{name}/skill.md.

The skill file must include:
- A clear description of what the skill does and when it triggers
- Step-by-step instructions Claude should follow
- Concrete usage examples
- Any required context or preconditions

After creating the file, read it back and confirm its full path.`,

  agent: `You are a Claude Code agent definition author. Create a new agent definition file at ~/.claude/agents/{name}.md.

The agent file must include:
- Name and one-line description
- An explicit list of allowed tools (Read, Write, Edit, Bash, etc.)
- Detailed behavioral instructions and constraints
- Example scenarios where this agent should be invoked

After creating the file, read it back and confirm its full path.`,

  hook: `You are a Claude Code hooks expert. Create a new Claude Code hook that runs in response to lifecycle events.

Steps:
1. Write the hook script to ~/.claude/hooks/{name}.sh and make it executable (chmod +x)
2. Show the exact ~/.claude/settings.json snippet needed to register it, including the correct event type (PreToolUse / PostToolUse / Stop / SessionStart / UserPromptSubmit) and any matchers
3. Explain what the hook does and when it fires

Confirm both the file path and the settings.json snippet when done.`,

  mcp: `You are an MCP (Model Context Protocol) server developer. Create a complete MCP server and integrate it with Claude Code.

Steps:
1. Implement the MCP server (prefer Node.js with npx-runnable package, or Python)
2. Add the configuration entry to ~/.claude/.mcp.json with the correct command and args
3. Provide verification steps to confirm the server loads correctly

The server should expose at least one tool. Confirm the config entry and file paths when done.`,
};

const TYPE_CONFIG: Record<
  ResourceType,
  { label: string; icon: React.ReactNode; color: string; placeholder: string }
> = {
  skill: {
    label: "Skill",
    icon: <Puzzle className="w-4 h-4" />,
    color: "text-purple-600 dark:text-purple-400",
    placeholder:
      'e.g. "A skill that writes commit messages following the Conventional Commits spec"',
  },
  agent: {
    label: "Agent",
    icon: <Bot className="w-4 h-4" />,
    color: "text-emerald-600 dark:text-emerald-400",
    placeholder:
      'e.g. "An agent specialised in reviewing pull requests for security vulnerabilities"',
  },
  hook: {
    label: "Hook",
    icon: <Zap className="w-4 h-4" />,
    color: "text-amber-600 dark:text-amber-400",
    placeholder:
      'e.g. "A PostToolUse hook that logs every file edit to a daily markdown journal"',
  },
  mcp: {
    label: "MCP",
    icon: <Plug className="w-4 h-4" />,
    color: "text-cyan-600 dark:text-cyan-400",
    placeholder:
      'e.g. "An MCP server that exposes my project\'s Jira board as searchable tools"',
  },
};

export default function CreateWithClaudeModal({
  open,
  onClose,
  onOpenTerminal,
}: {
  open: boolean;
  onClose: () => void;
  onOpenTerminal: (spec: OpenTerminalSpec) => void;
}) {
  const [type, setType] = useState<ResourceType>("skill");
  const [userInput, setUserInput] = useState("");
  const [wrapperPrompt, setWrapperPrompt] = useState(WRAPPER_PROMPTS.skill);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  if (!open) return null;

  const handleTypeChange = (t: ResourceType) => {
    setType(t);
    setWrapperPrompt(WRAPPER_PROMPTS[t]);
    setError("");
  };

  const handleLaunch = async () => {
    if (!userInput.trim()) {
      setError("Lütfen ne oluşturmak istediğinizi yazın.");
      return;
    }
    setBusy(true);
    setError("");
    try {
      const combined = `${wrapperPrompt}\n\n---\nUser request: ${userInput.trim()}`;
      const ts = Date.now();
      const tmpPath = `/tmp/apex-create-${type}-${ts}.md`;
      await invoke("write_file", { path: tmpPath, content: combined });
      const cfg = TYPE_CONFIG[type];
      onOpenTerminal({
        key: `create-${type}-${ts}`,
        name: `Create ${cfg.label}`,
        kind: "terminal",
        initialCommand: `claude "$(cat ${tmpPath})"`,
      });
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
      <div className="w-full max-w-2xl mx-4 rounded-xl border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 shadow-2xl flex flex-col overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-neutral-200 dark:border-neutral-700">
          <div className="flex items-center gap-2">
            <Sparkles className="w-4 h-4 text-indigo-500" />
            <span className="text-sm font-semibold text-neutral-800 dark:text-neutral-200">
              Create with Claude
            </span>
          </div>
          <button
            onClick={onClose}
            className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        <div className="p-5 flex flex-col gap-5">
          {/* Type selector */}
          <div>
            <p className="text-xs font-medium text-neutral-500 dark:text-neutral-400 mb-2 uppercase tracking-wider">
              Resource type
            </p>
            <div className="grid grid-cols-4 gap-2">
              {(Object.keys(TYPE_CONFIG) as ResourceType[]).map((t) => {
                const cfg = TYPE_CONFIG[t];
                const active = type === t;
                return (
                  <button
                    key={t}
                    onClick={() => handleTypeChange(t)}
                    className={`flex flex-col items-center gap-1.5 px-3 py-3 rounded-lg border text-xs font-medium transition-colors cursor-pointer ${
                      active
                        ? "bg-indigo-600 dark:bg-indigo-500 border-indigo-700 dark:border-indigo-400 text-white shadow-sm"
                        : "border-neutral-200 dark:border-neutral-700 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-50 dark:hover:bg-neutral-800"
                    }`}
                  >
                    <span className={active ? "text-indigo-600 dark:text-indigo-400" : cfg.color}>
                      {cfg.icon}
                    </span>
                    {cfg.label}
                  </button>
                );
              })}
            </div>
          </div>

          {/* User input */}
          <div>
            <label className="text-xs font-medium text-neutral-500 dark:text-neutral-400 mb-1.5 block uppercase tracking-wider">
              Ne oluşturmak istiyorsunuz?
            </label>
            <textarea
              className="w-full h-24 px-3 py-2 text-sm rounded-lg border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-800 text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 dark:placeholder:text-neutral-500 focus:outline-none focus:ring-2 focus:ring-indigo-400 dark:focus:ring-indigo-500 resize-none"
              placeholder={TYPE_CONFIG[type].placeholder}
              value={userInput}
              onChange={(e) => setUserInput(e.target.value)}
            />
          </div>

          {/* Wrapper prompt (editable) */}
          <div>
            <label className="text-xs font-medium text-neutral-500 dark:text-neutral-400 mb-1.5 block uppercase tracking-wider">
              Claude'a gönderilecek wrapper prompt{" "}
              <span className="normal-case font-normal">(EN, düzenlenebilir)</span>
            </label>
            <textarea
              className="w-full h-36 px-3 py-2 text-xs font-mono rounded-lg border border-neutral-200 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-800/60 text-neutral-700 dark:text-neutral-300 focus:outline-none focus:ring-2 focus:ring-indigo-400 dark:focus:ring-indigo-500 resize-none"
              value={wrapperPrompt}
              onChange={(e) => setWrapperPrompt(e.target.value)}
            />
          </div>

          {error && (
            <p className="text-xs text-rose-600 dark:text-rose-400">{error}</p>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-3 px-5 py-4 border-t border-neutral-200 dark:border-neutral-700">
          <button
            onClick={onClose}
            className="px-4 py-2 text-xs rounded-lg border border-neutral-200 dark:border-neutral-700 text-neutral-600 dark:text-neutral-400 hover:bg-neutral-50 dark:hover:bg-neutral-800 transition-colors cursor-pointer"
          >
            İptal
          </button>
          <button
            onClick={handleLaunch}
            disabled={busy || !userInput.trim()}
            className="flex items-center gap-2 px-4 py-2 text-xs rounded-lg bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300 dark:disabled:bg-indigo-800 text-white font-medium transition-colors cursor-pointer disabled:cursor-not-allowed"
          >
            <Sparkles className="w-3.5 h-3.5" />
            {busy ? "Açılıyor…" : "Terminalde Aç"}
          </button>
        </div>
      </div>
    </div>
  );
}
