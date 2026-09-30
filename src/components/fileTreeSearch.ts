// Created by Claude — Classification: INTERNAL
//
// Lets a host own the FileTree's "filter files" toggle. The v0.4 Files section puts the
// search button in its own header row, so the tree must not draw a second, near-empty
// row just for the icon. Without a provider FileTree keeps its built-in toggle row.

import { createContext } from "react";

export interface FileTreeSearchControl {
  open: boolean;
  setOpen: (open: boolean) => void;
}

export const FileTreeSearchContext = createContext<FileTreeSearchControl | null>(null);
