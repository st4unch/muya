/** "Resume Claude sessions on launch": restored Claude tabs rejoin their conversation
 *  at startup instead of waiting for a click. Off unless the user turns it on. */
export const RESUME_ON_LAUNCH_KEY = "muya.resumeOnLaunch";

export function loadResumeOnLaunch(): boolean {
  try {
    return localStorage.getItem(RESUME_ON_LAUNCH_KEY) === "1";
  } catch {
    return false;
  }
}

export function saveResumeOnLaunch(on: boolean): void {
  try {
    if (on) localStorage.setItem(RESUME_ON_LAUNCH_KEY, "1");
    else localStorage.removeItem(RESUME_ON_LAUNCH_KEY);
  } catch {
    /* storage unavailable — the switch just won't persist */
  }
}
