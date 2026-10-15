/**
 * Click test for Scribe in Electron's window (macOS).
 *
 * Opens a window set up like the app's (hidden title bar, hidden window
 * buttons, a draggable strip), attaches Scribe's view from desktop/scribe-embed
 * the way the app does, posts real mouse-down/up events into the window, and
 * checks which side received them:
 *
 *   none                  clicks reach the page
 *   scribe-hidden         clicks still reach the page (Scribe is attached but hidden)
 *   scribe-shown-hidden   same, after showing and hiding Scribe again
 *   scribe-visible        the page gets nothing; Scribe's view is on top
 *
 * SwiftUI's hosting view answers hit tests even while hidden, which once made
 * a hidden Scribe swallow every click in the app; this is the guard for that.
 *
 * Run: npm run test:clicks (builds the probe addon and needs build:scribe first).
 * Each case runs in its own Electron process; this file is both the driver
 * and, with CLICK_CASE set, the Electron main script.
 */

const path = require('node:path')

const embed = process.env.SCRIBE_EMBED_DIR || path.join(__dirname, '../../scribe-embed')
const CASES = {
  none: { attach: false, expectPage: true },
  'scribe-hidden': { attach: true, expectPage: true },
  'scribe-shown-hidden': { attach: true, toggle: true, expectPage: true },
  'scribe-visible': { attach: true, show: true, expectPage: false },
}

if (process.env.CLICK_CASE) runCase(process.env.CLICK_CASE)
else drive()

function drive() {
  const { spawnSync } = require('node:child_process')
  const electron = require(path.join(__dirname, '../../node_modules/electron'))
  let failed = 0
  for (const name of Object.keys(CASES)) {
    const env = { ...process.env, CLICK_CASE: name }
    delete env.ELECTRON_RUN_AS_NODE
    const r = spawnSync(electron, [__filename], { env, encoding: 'utf8', timeout: 60000 })
    const line = (r.stdout || '').split('\n').find((l) => l.startsWith('RESULT')) ?? ''
    const ok = line.includes(' pass')
    if (!ok) failed++
    console.log(ok ? `ok    ${name}` : `FAIL  ${name}  ${line || (r.stderr || '').trim().split('\n').pop()}`)
  }
  if (failed) {
    console.error(`${failed} click case(s) failed`)
    process.exit(1)
  }
}

function runCase(name) {
  const { app, BrowserWindow } = require('electron')
  const probe = require(path.join(__dirname, 'build/Release/probe.node'))
  const spec = CASES[name]
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  const html = `<html><body style="margin:0;background:#222">
    <div style="height:40px;-webkit-app-region:drag;background:#333"></div>
    <button id=b style="position:absolute;left:100px;top:200px;width:200px;height:100px">click</button>
    <script>window.clicks=0;document.getElementById('b').onclick=()=>window.clicks++</script></body></html>`

  app.whenReady().then(async () => {
    const win = new BrowserWindow({ width: 900, height: 640, titleBarStyle: 'hidden' })
    win.setWindowButtonVisibility(false)
    await win.loadURL('data:text/html,' + encodeURIComponent(html))
    const handle = win.getNativeWindowHandle()
    if (spec.attach) {
      const bridge = require(path.join(embed, 'scribe_bridge.node'))
      bridge.load(path.join(embed, 'libScribeEmbed.dylib'))
      bridge.attach(handle, 'Electron', '', '')
      if (spec.toggle) {
        bridge.setVisible(true)
        await sleep(400)
        bridge.setVisible(false)
      }
      if (spec.show) bridge.setVisible(true)
    }
    await sleep(1000)
    probe.postClick(handle, 200, 250)
    await sleep(800)
    const clicks = await win.webContents.executeJavaScript('window.clicks')
    const pass = spec.expectPage ? clicks > 0 : clicks === 0
    console.log(`RESULT ${name} page-clicks=${clicks} ${pass ? 'pass' : 'fail'}`)
    if (!pass) console.log(probe.describe(handle, 200, 250))
    app.exit(0)
  })
}
