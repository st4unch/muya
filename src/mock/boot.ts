// Created by Claude — Classification: INTERNAL
//
// Imported FIRST by src/main.tsx. ES modules evaluate their imports in order, so the
// mock IPC (and the localStorage seed the app restores tabs from) is in place before
// App.tsx or anything else is evaluated. In a production build `import.meta.env.DEV`
// is the literal `false`, the call is dead code, and the mock module is dropped
// entirely — verified by grepping dist/ for the fixture names.
import { maybeInstallMock } from "./installMock";

if (import.meta.env.DEV) maybeInstallMock();
