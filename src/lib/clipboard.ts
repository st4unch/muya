import { writeText as tauriWriteText } from "@tauri-apps/plugin-clipboard-manager";

/**
 * Copy text to the OS clipboard. `navigator.clipboard.writeText()` is unreliable inside
 * Tauri's WKWebView — it can throw `NotAllowedError` ("not allowed by the user agent or
 * platform") even with no permission dialog to accept, because the web Clipboard API's
 * focus/permission model doesn't map cleanly onto a native webview. The Tauri
 * clipboard-manager plugin talks to the OS clipboard directly and doesn't hit that wall;
 * it's what every Copy button in the app should call. Falls back to the web API (e.g. in
 * unit tests, where the plugin isn't mocked) so callers don't need two code paths.
 */
export async function copyToClipboard(text: string): Promise<void> {
  try {
    await tauriWriteText(text);
  } catch {
    await navigator.clipboard.writeText(text);
  }
}
