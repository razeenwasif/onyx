import { app } from 'electron'

/**
 * Whether this is the built app rather than a dev run. `app.isPackaged`
 * can't tell on its own: Electron decides it from the executable's name, and
 * a packaged app named Electron looks exactly like the dev binary. Dev runs
 * start through Electron's default app (`electron .`), which sets
 * `process.defaultApp`; a packaged app never does.
 */
export const isPackaged = app.isPackaged || !process.defaultApp
