// Option/Alt + arrow → the byte sequence to send to the PTY.
//
// macOS xterm emits the modified-arrow CSI (e.g. "\x1b[1;3C" for Option+Right),
// which zsh/bash render as literal ";3C" noise when unbound. We send what every
// shell already understands instead: readline meta word-nav for Left/Right, and
// the plain arrow for Up/Down. This mirrors Terminal.app / iTerm2 ("Esc+").
export function altArrowSeq(key: string): string | null {
  switch (key) {
    case "ArrowLeft":
      return "\x1bb"; // meta-b — backward one word
    case "ArrowRight":
      return "\x1bf"; // meta-f — forward one word
    case "ArrowUp":
      return "\x1b[A"; // plain up (history) — strip the broken modifier
    case "ArrowDown":
      return "\x1b[B"; // plain down
    default:
      return null;
  }
}
