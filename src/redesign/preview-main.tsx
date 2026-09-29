// Created by Claude — Classification: INTERNAL
//
// Scratch entry point for the visual pixel-diff check (PROMPT.md §7) — NOT part
// of the shipped app (src/main.tsx is unchanged). Mounts Preview full-window.
// Query params: ?theme=light|dark|system (default dark), ?screen=control|grid.

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/500.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/jetbrains-mono/400.css";
import "@fontsource/jetbrains-mono/500.css";
import "@fontsource/jetbrains-mono/700.css";
import "../styles/tokens.css";
import "./redesign.css";
import { Preview } from "./Preview";
import type { ThemePreference } from "./types";

const params = new URLSearchParams(window.location.search);
const theme = (params.get("theme") as ThemePreference) ?? "dark";
const screen = params.get("screen") === "grid" ? "grid" : "control";
const stress = params.get("stress") === "1";

document.documentElement.dataset.theme = theme === "system" ? "dark" : theme;

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <div style={{ width: "100vw", height: "100vh" }}>
      <Preview screen={screen} theme={theme} stress={stress} />
    </div>
  </StrictMode>,
);
