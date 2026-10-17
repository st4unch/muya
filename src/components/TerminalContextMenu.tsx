// Created by Claude — Classification: INTERNAL
//
// Right-click menu of every terminal tab (plain terminals, Claude sessions, SSH):
// copy/paste and the other usual terminal actions. Built from the redesign menu parts.

import { createPortal } from "react-dom";
import { MenuItem, MenuPopover, MenuSeparator } from "../redesign/Menus";

export interface TerminalMenuActions {
  copy: () => void;
  paste: () => void;
  pasteAsPath: () => void;
  selectAll: () => void;
  openLink: () => void;
  find: () => void;
  clear: () => void;
  font: (step: -1 | 0 | 1) => void;
}

export default function TerminalContextMenu({
  x,
  y,
  hasSelection,
  link,
  actions,
  onClose,
}: {
  x: number;
  y: number;
  hasSelection: boolean;
  /** The selection when it is a web URL — shows "Open Link". */
  link?: string;
  actions: TerminalMenuActions;
  onClose: () => void;
}) {
  const run = (fn: () => void) => () => {
    onClose();
    fn();
  };
  const width = 230;
  // Open upwards when the menu would run off the bottom of the window.
  const place = y > window.innerHeight - 340 ? "above" : "below";
  return createPortal(
    <MenuPopover label="Terminal" autoFocus width={width} onClose={onClose} anchor={{ x, y, align: "left", place }}>
      <MenuItem label="Copy" hint="⌘C" disabled={!hasSelection} onSelect={run(actions.copy)} />
      <MenuItem label="Paste" hint="⌘V" onSelect={run(actions.paste)} />
      <MenuItem label="Paste as Path" onSelect={run(actions.pasteAsPath)} />
      <MenuItem label="Select All" onSelect={run(actions.selectAll)} />
      {link && (
        <>
          <MenuSeparator />
          <MenuItem label="Open Link" onSelect={run(actions.openLink)} />
        </>
      )}
      <MenuSeparator />
      <MenuItem label="Find…" hint="⌘F" onSelect={run(actions.find)} />
      <MenuItem label="Clear Scrollback" onSelect={run(actions.clear)} />
      <MenuSeparator />
      <MenuItem label="Bigger Text" hint="⌘=" onSelect={run(() => actions.font(1))} />
      <MenuItem label="Smaller Text" hint="⌘-" onSelect={run(() => actions.font(-1))} />
      <MenuItem label="Default Text Size" hint="⌘0" onSelect={run(() => actions.font(0))} />
    </MenuPopover>,
    document.body,
  );
}
