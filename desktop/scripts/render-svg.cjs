/**
 * Rasterize an SVG to a transparent PNG with Chromium, via the project's own
 * Electron. ImageMagick's built-in SVG renderer drops Bézier/arc strokes, so
 * generate-icons.sh renders one large master here and only resizes with magick.
 *
 * Usage: electron scripts/render-svg.cjs <in.svg> <out.png> [size=1024]
 */
const { app, BrowserWindow } = require('electron')
const fs = require('node:fs')

const [svgPath, outPath, sizeArg] = process.argv.slice(2).filter((a) => !a.startsWith('--'))
const size = Number(sizeArg) || 1024

if (!svgPath || !outPath) {
  console.error('usage: electron scripts/render-svg.cjs <in.svg> <out.png> [size]')
  process.exit(2)
}

app.disableHardwareAcceleration()
app.dock?.hide()

app.whenReady().then(async () => {
  try {
    const b64 = fs.readFileSync(svgPath).toString('base64')
    const win = new BrowserWindow({ show: false })
    await win.loadURL('about:blank')
    // Drawing onto a canvas at the target size keeps the output exactly
    // size×size with real transparency, independent of the display's scale.
    const dataUrl = await win.webContents.executeJavaScript(`new Promise((resolve, reject) => {
      const img = new Image()
      img.onload = () => {
        const c = document.createElement('canvas')
        c.width = c.height = ${size}
        c.getContext('2d').drawImage(img, 0, 0, ${size}, ${size})
        resolve(c.toDataURL('image/png'))
      }
      img.onerror = () => reject(new Error('SVG failed to load'))
      img.src = 'data:image/svg+xml;base64,${b64}'
    })`)
    fs.writeFileSync(outPath, Buffer.from(dataUrl.split(',')[1], 'base64'))
    app.exit(0)
  } catch (err) {
    console.error(err)
    app.exit(1)
  }
})
