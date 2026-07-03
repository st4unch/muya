import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { FileText, RefreshCw } from "lucide-react";

// Lightweight markdown → HTML (headers, bold, italic, code blocks, inline code,
// blockquotes, unordered/ordered lists, links, horizontal rules).
// dangerouslySetInnerHTML is safe here: content comes only from local filesystem.
function mdToHtml(md: string): string {
  let html = md
    // Fenced code blocks
    .replace(/```(\w*)\n([\s\S]*?)```/g, (_, lang, code) => {
      const escaped = code.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
      return `<pre class="md-pre"><code class="md-code">${escaped.trimEnd()}</code></pre>`;
    })
    // Headings
    .replace(/^###### (.+)$/gm, "<h6>$1</h6>")
    .replace(/^##### (.+)$/gm, "<h5>$1</h5>")
    .replace(/^#### (.+)$/gm, "<h4>$1</h4>")
    .replace(/^### (.+)$/gm, "<h3>$1</h3>")
    .replace(/^## (.+)$/gm, "<h2>$1</h2>")
    .replace(/^# (.+)$/gm, "<h1>$1</h1>")
    // Horizontal rule
    .replace(/^(-{3,}|_{3,}|\*{3,})$/gm, "<hr />")
    // Blockquote
    .replace(/^> (.+)$/gm, "<blockquote>$1</blockquote>")
    // Unordered list items
    .replace(/^\s*[-*+] (.+)$/gm, "<li>$1</li>")
    // Ordered list items
    .replace(/^\s*\d+\. (.+)$/gm, "<li>$1</li>")
    // Bold + italic
    .replace(/\*\*\*(.+?)\*\*\*/g, "<strong><em>$1</em></strong>")
    .replace(/___(.+?)___/g, "<strong><em>$1</em></strong>")
    // Bold
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/__(.+?)__/g, "<strong>$1</strong>")
    // Italic
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/_(.+?)_/g, "<em>$1</em>")
    // Inline code
    .replace(/`([^`]+)`/g, '<code class="md-inline-code">$1</code>')
    // Links
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>')
    // Paragraph breaks (double newline)
    .replace(/\n{2,}/g, "</p><p>")
    // Single newlines inside paragraphs
    .replace(/\n/g, "<br />");

  // Wrap consecutive <li> in <ul>
  html = html.replace(/(<li>.*?<\/li>(\s*<br \/>)*)+/g, (m) => {
    const items = m.replace(/<br \/>/g, "");
    return `<ul>${items}</ul>`;
  });

  return `<p>${html}</p>`;
}

export default function MarkdownViewer({
  filePath,
}: {
  filePath?: string;
}) {
  const [content, setContent] = useState<string>("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const load = async (path: string) => {
    setLoading(true);
    setError("");
    try {
      const text = await invoke<string>("read_file", { path });
      setContent(text);
    } catch (e) {
      setError(String(e));
      setContent("");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (filePath) void load(filePath);
    else setContent("");
  }, [filePath]);

  if (!filePath) {
    return (
      <div className="flex-1 flex flex-col items-center justify-center gap-2 text-neutral-400 dark:text-neutral-500">
        <FileText className="h-8 w-8 opacity-30" />
        <p className="text-xs font-mono">Select a .md file to preview</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-1.5 border-b border-neutral-200 dark:border-[#3d3f44] bg-neutral-100 dark:bg-[#1e1f23] shrink-0">
        <span className="text-[10px] font-mono text-neutral-400 truncate max-w-[200px]">
          {filePath.split("/").pop()}
        </span>
        <button
          type="button"
          onClick={() => void load(filePath)}
          className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 cursor-pointer transition-colors"
          title="Reload"
        >
          <RefreshCw className={`h-3 w-3 ${loading ? "animate-spin" : ""}`} />
        </button>
      </div>

      {/* Rendered content */}
      <div className="flex-1 overflow-y-auto px-5 py-4">
        {error ? (
          <p className="text-xs font-mono text-rose-500">{error}</p>
        ) : (
          <div
            className="md-body"
            // eslint-disable-next-line react/no-danger
            dangerouslySetInnerHTML={{ __html: mdToHtml(content) }}
          />
        )}
      </div>

      <style>{`
        .md-body { font-size: 13px; line-height: 1.7; color: #374151; }
        .md-body h1 { font-size: 1.5em; font-weight: 700; margin: 0.8em 0 0.4em; color: #111827; border-bottom: 1px solid #e5e7eb; padding-bottom: 0.2em; }
        .md-body h2 { font-size: 1.25em; font-weight: 700; margin: 0.8em 0 0.3em; color: #111827; }
        .md-body h3 { font-size: 1.1em; font-weight: 600; margin: 0.6em 0 0.2em; color: #1f2937; }
        .md-body h4, .md-body h5, .md-body h6 { font-weight: 600; margin: 0.5em 0 0.2em; color: #374151; }
        .md-body p { margin: 0.5em 0; }
        .md-body strong { font-weight: 700; color: #111827; }
        .md-body em { font-style: italic; }
        .md-body a { color: #4f46e5; text-decoration: underline; }
        .md-body ul { list-style: disc; padding-left: 1.4em; margin: 0.4em 0; }
        .md-body ol { list-style: decimal; padding-left: 1.4em; margin: 0.4em 0; }
        .md-body li { margin: 0.15em 0; }
        .md-body blockquote { border-left: 3px solid #d1d5db; padding-left: 0.8em; color: #6b7280; margin: 0.5em 0; }
        .md-body hr { border: none; border-top: 1px solid #e5e7eb; margin: 1em 0; }
        .md-body .md-pre { background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 6px; padding: 0.8em 1em; overflow-x: auto; margin: 0.6em 0; }
        .md-body .md-code { font-family: "JetBrains Mono", ui-monospace, monospace; font-size: 12px; color: #1f2937; }
        .md-body .md-inline-code { background: #f3f4f6; border: 1px solid #e5e7eb; border-radius: 3px; padding: 0.1em 0.3em; font-family: "JetBrains Mono", ui-monospace, monospace; font-size: 11px; color: #7c3aed; }

        :root.dark .md-body { color: #d4d4d4; }
        :root.dark .md-body h1 { color: #f0f0f0; border-bottom-color: #3d3f44; }
        :root.dark .md-body h2 { color: #f0f0f0; }
        :root.dark .md-body h3 { color: #e0e0e0; }
        :root.dark .md-body h4, :root.dark .md-body h5, :root.dark .md-body h6 { color: #d4d4d4; }
        :root.dark .md-body strong { color: #f0f0f0; }
        :root.dark .md-body a { color: #818cf8; }
        :root.dark .md-body blockquote { border-left-color: #3d3f44; color: #a0a0a0; }
        :root.dark .md-body hr { border-top-color: #3d3f44; }
        :root.dark .md-body .md-pre { background: #1e1f23; border-color: #3d3f44; }
        :root.dark .md-body .md-code { color: #e5e5e5; }
        :root.dark .md-body .md-inline-code { background: #1e1f23; border-color: #3d3f44; color: #c084fc; }
      `}</style>
    </div>
  );
}
