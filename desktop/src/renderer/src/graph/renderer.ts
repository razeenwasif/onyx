/**
 * WebGL2 renderer for the graph view.
 *
 * Three instanced draw calls per frame — links, arrowheads, nodes — so a
 * 10,000-node vault still paints in well under a millisecond of GPU time.
 * Circles are signed-distance discs in the fragment shader (crisp at any zoom,
 * no texture atlas), links are camera-space quads so thickness stays constant
 * in screen pixels the way Obsidian's do.
 *
 * Labels are *not* drawn here: text belongs on a 2D overlay canvas where the
 * browser's font rasterizer does a far better job than an SDF atlas would.
 */

export interface Camera {
  /** World-space point at the center of the viewport. */
  x: number
  y: number
  /** Screen pixels per world unit. */
  scale: number
}

const NODE_VS = `#version 300 es
precision highp float;

layout(location = 0) in vec2 aCorner;      // unit quad, -1..1
layout(location = 1) in vec2 aCenter;      // world position
layout(location = 2) in float aRadius;     // world radius
layout(location = 3) in vec4 aColor;
layout(location = 4) in float aRing;       // 0 = plain, >0 = ring width in px

uniform vec2 uResolution;
uniform vec2 uCamera;
uniform float uScale;

out vec2 vLocal;
out vec4 vColor;
out float vPixelRadius;
out float vRing;

void main() {
  // Pad the quad by 1.5px so the antialiased rim is never clipped.
  float px = aRadius * uScale;
  float pad = 1.0 + 1.5 / max(px, 0.001);
  vLocal = aCorner * pad;

  vec2 world = aCenter + aCorner * aRadius * pad;
  vec2 screen = (world - uCamera) * uScale + uResolution * 0.5;
  vec2 clip = (screen / uResolution) * 2.0 - 1.0;
  gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);

  vColor = aColor;
  vPixelRadius = px;
  vRing = aRing;
}`

const NODE_FS = `#version 300 es
precision highp float;

in vec2 vLocal;
in vec4 vColor;
in float vPixelRadius;
in float vRing;

out vec4 outColor;

void main() {
  float d = length(vLocal);                    // 0 at center, 1 at the rim
  float aa = 1.0 / max(vPixelRadius, 1.0);     // one screen pixel, in local units
  float disc = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, d);
  if (disc <= 0.0) discard;

  vec4 c = vColor;
  if (vRing > 0.0) {
    // A bright rim on hovered / focused nodes.
    float inner = 1.0 - vRing / max(vPixelRadius, 1.0);
    float ring = smoothstep(inner - aa, inner + aa, d);
    c.rgb = mix(c.rgb, vec3(1.0), ring * 0.75);
  }
  outColor = vec4(c.rgb, c.a * disc);
}`

const LINK_VS = `#version 300 es
precision highp float;

layout(location = 0) in vec2 aCorner;   // (0..1, -0.5..0.5)
layout(location = 1) in vec2 aFrom;
layout(location = 2) in vec2 aTo;
layout(location = 3) in float aWidth;   // screen pixels
layout(location = 4) in vec4 aColor;

uniform vec2 uResolution;
uniform vec2 uCamera;
uniform float uScale;

out vec4 vColor;
out float vEdge;
out float vWidth;

void main() {
  vec2 p0 = (aFrom - uCamera) * uScale + uResolution * 0.5;
  vec2 p1 = (aTo - uCamera) * uScale + uResolution * 0.5;
  vec2 dir = p1 - p0;
  float len = length(dir);
  vec2 unit = len > 0.0001 ? dir / len : vec2(1.0, 0.0);
  vec2 normal = vec2(-unit.y, unit.x);

  float w = max(aWidth, 0.6) + 1.0;   // +1px for the antialiased edge
  vec2 screen = p0 + unit * (aCorner.x * len) + normal * (aCorner.y * w);
  vec2 clip = (screen / uResolution) * 2.0 - 1.0;
  gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);

  vColor = aColor;
  vEdge = aCorner.y * 2.0;   // -1..1 across the ribbon
  vWidth = w;
}`

const LINK_FS = `#version 300 es
precision highp float;

in vec4 vColor;
in float vEdge;
in float vWidth;

out vec4 outColor;

void main() {
  // Fade the outermost pixel so thin links don't shimmer.
  float aa = 2.0 / max(vWidth, 1.0);
  float a = 1.0 - smoothstep(1.0 - aa, 1.0, abs(vEdge));
  if (a <= 0.0) discard;
  outColor = vec4(vColor.rgb, vColor.a * a);
}`

const ARROW_VS = `#version 300 es
precision highp float;

layout(location = 0) in vec2 aCorner;   // triangle in local arrow space
layout(location = 1) in vec2 aFrom;
layout(location = 2) in vec2 aTo;
layout(location = 3) in float aSize;    // screen pixels
layout(location = 4) in vec4 aColor;
layout(location = 5) in float aInset;   // pull back from the target, in px

uniform vec2 uResolution;
uniform vec2 uCamera;
uniform float uScale;

out vec4 vColor;

void main() {
  vec2 p0 = (aFrom - uCamera) * uScale + uResolution * 0.5;
  vec2 p1 = (aTo - uCamera) * uScale + uResolution * 0.5;
  vec2 dir = p1 - p0;
  float len = length(dir);
  vec2 unit = len > 0.0001 ? dir / len : vec2(1.0, 0.0);
  vec2 normal = vec2(-unit.y, unit.x);

  vec2 tip = p1 - unit * aInset;
  vec2 screen = tip + unit * (aCorner.x * aSize) + normal * (aCorner.y * aSize);
  vec2 clip = (screen / uResolution) * 2.0 - 1.0;
  gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);
  vColor = aColor;
}`

const ARROW_FS = `#version 300 es
precision highp float;
in vec4 vColor;
out vec4 outColor;
void main() { outColor = vColor; }`

function compile(gl: WebGL2RenderingContext, type: number, src: string): WebGLShader {
  const sh = gl.createShader(type)!
  gl.shaderSource(sh, src)
  gl.compileShader(sh)
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(sh)
    gl.deleteShader(sh)
    throw new Error(`graph shader failed to compile: ${log}`)
  }
  return sh
}

function link(gl: WebGL2RenderingContext, vs: string, fs: string): WebGLProgram {
  const p = gl.createProgram()!
  gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, vs))
  gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, fs))
  gl.linkProgram(p)
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
    throw new Error(`graph program failed to link: ${gl.getProgramInfoLog(p)}`)
  }
  return p
}

interface Uniforms {
  resolution: WebGLUniformLocation | null
  camera: WebGLUniformLocation | null
  scale: WebGLUniformLocation | null
}

function uniformsOf(gl: WebGL2RenderingContext, p: WebGLProgram): Uniforms {
  return {
    resolution: gl.getUniformLocation(p, 'uResolution'),
    camera: gl.getUniformLocation(p, 'uCamera'),
    scale: gl.getUniformLocation(p, 'uScale'),
  }
}

/** Per-frame instance data the view fills in. Sized to the visible subgraph. */
export interface FrameData {
  nodeCount: number
  /** xy per node, world space. */
  nodeXY: Float32Array
  nodeRadius: Float32Array
  /** rgba per node, 0..1. */
  nodeColor: Float32Array
  nodeRing: Float32Array

  linkCount: number
  linkFrom: Float32Array
  linkTo: Float32Array
  linkWidth: Float32Array
  linkColor: Float32Array
  /** Arrow inset per link (target radius in screen px), only used when arrows are on. */
  linkInset: Float32Array
  arrows: boolean
  arrowSize: number
}

export class GraphRenderer {
  private gl: WebGL2RenderingContext
  private nodeProg: WebGLProgram
  private linkProg: WebGLProgram
  private arrowProg: WebGLProgram
  private nodeU: Uniforms
  private linkU: Uniforms
  private arrowU: Uniforms

  private nodeVao: WebGLVertexArrayObject
  private linkVao: WebGLVertexArrayObject
  private arrowVao: WebGLVertexArrayObject

  private buf: Record<string, WebGLBuffer> = {}
  private capacity = { nodes: 0, links: 0 }

  constructor(private canvas: HTMLCanvasElement) {
    const gl = canvas.getContext('webgl2', {
      alpha: true,
      antialias: false,
      premultipliedAlpha: false,
      preserveDrawingBuffer: false,
      powerPreference: 'high-performance',
    })
    if (!gl) throw new Error('WebGL2 is unavailable')
    this.gl = gl

    this.nodeProg = link(gl, NODE_VS, NODE_FS)
    this.linkProg = link(gl, LINK_VS, LINK_FS)
    this.arrowProg = link(gl, ARROW_VS, ARROW_FS)
    this.nodeU = uniformsOf(gl, this.nodeProg)
    this.linkU = uniformsOf(gl, this.linkProg)
    this.arrowU = uniformsOf(gl, this.arrowProg)

    gl.enable(gl.BLEND)
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    gl.disable(gl.DEPTH_TEST)

    this.nodeVao = gl.createVertexArray()!
    this.linkVao = gl.createVertexArray()!
    this.arrowVao = gl.createVertexArray()!
    this.setupNodeVao()
    this.setupLinkVao()
    this.setupArrowVao()
  }

  private makeBuffer(name: string, data: BufferSource, usage: number): WebGLBuffer {
    const gl = this.gl
    const b = gl.createBuffer()!
    gl.bindBuffer(gl.ARRAY_BUFFER, b)
    gl.bufferData(gl.ARRAY_BUFFER, data, usage)
    this.buf[name] = b
    return b
  }

  private attr(
    loc: number,
    buffer: WebGLBuffer,
    size: number,
    divisor: number,
  ): void {
    const gl = this.gl
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
    gl.enableVertexAttribArray(loc)
    gl.vertexAttribPointer(loc, size, gl.FLOAT, false, 0, 0)
    gl.vertexAttribDivisor(loc, divisor)
  }

  private setupNodeVao(): void {
    const gl = this.gl
    gl.bindVertexArray(this.nodeVao)
    const quad = new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1])
    const cornerBuf = this.makeBuffer('nodeCorner', quad, gl.STATIC_DRAW)
    this.attr(0, cornerBuf, 2, 0)
    this.buf.nodeXY = gl.createBuffer()!
    this.buf.nodeRadius = gl.createBuffer()!
    this.buf.nodeColor = gl.createBuffer()!
    this.buf.nodeRing = gl.createBuffer()!
    this.attr(1, this.buf.nodeXY, 2, 1)
    this.attr(2, this.buf.nodeRadius, 1, 1)
    this.attr(3, this.buf.nodeColor, 4, 1)
    this.attr(4, this.buf.nodeRing, 1, 1)
    gl.bindVertexArray(null)
  }

  private setupLinkVao(): void {
    const gl = this.gl
    gl.bindVertexArray(this.linkVao)
    // A unit ribbon: x along the segment (0..1), y across it (-0.5..0.5).
    const ribbon = new Float32Array([0, -0.5, 1, -0.5, 0, 0.5, 1, 0.5])
    const cornerBuf = this.makeBuffer('linkCorner', ribbon, gl.STATIC_DRAW)
    this.attr(0, cornerBuf, 2, 0)
    this.buf.linkFrom = gl.createBuffer()!
    this.buf.linkTo = gl.createBuffer()!
    this.buf.linkWidth = gl.createBuffer()!
    this.buf.linkColor = gl.createBuffer()!
    this.attr(1, this.buf.linkFrom, 2, 1)
    this.attr(2, this.buf.linkTo, 2, 1)
    this.attr(3, this.buf.linkWidth, 1, 1)
    this.attr(4, this.buf.linkColor, 4, 1)
    gl.bindVertexArray(null)
  }

  private setupArrowVao(): void {
    const gl = this.gl
    gl.bindVertexArray(this.arrowVao)
    // A backwards-pointing triangle whose tip sits at the origin.
    const tri = new Float32Array([0, 0, -1.6, 0.75, -1.6, -0.75])
    const cornerBuf = this.makeBuffer('arrowCorner', tri, gl.STATIC_DRAW)
    this.attr(0, cornerBuf, 2, 0)
    this.attr(1, this.buf.linkFrom, 2, 1)
    this.attr(2, this.buf.linkTo, 2, 1)
    this.buf.arrowSize = gl.createBuffer()!
    this.attr(3, this.buf.arrowSize, 1, 1)
    this.attr(4, this.buf.linkColor, 4, 1)
    this.buf.linkInset = gl.createBuffer()!
    this.attr(5, this.buf.linkInset, 1, 1)
    gl.bindVertexArray(null)
  }

  private upload(name: string, data: Float32Array, count: number, stride: number): void {
    const gl = this.gl
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buf[name])
    const needed = count * stride
    gl.bufferData(gl.ARRAY_BUFFER, data.subarray(0, needed), gl.DYNAMIC_DRAW)
  }

  /** Size the drawing buffer to the element, honouring devicePixelRatio. */
  resize(): { width: number; height: number; dpr: number } {
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const w = Math.max(1, Math.round(this.canvas.clientWidth * dpr))
    const h = Math.max(1, Math.round(this.canvas.clientHeight * dpr))
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w
      this.canvas.height = h
    }
    this.gl.viewport(0, 0, w, h)
    return { width: w, height: h, dpr }
  }

  clear(bg: [number, number, number, number]): void {
    const gl = this.gl
    gl.clearColor(bg[0], bg[1], bg[2], bg[3])
    gl.clear(gl.COLOR_BUFFER_BIT)
  }

  draw(frame: FrameData, camera: Camera, dpr: number): void {
    const gl = this.gl
    const w = this.canvas.width
    const h = this.canvas.height
    const scale = camera.scale * dpr

    if (frame.linkCount > 0) {
      this.upload('linkFrom', frame.linkFrom, frame.linkCount, 2)
      this.upload('linkTo', frame.linkTo, frame.linkCount, 2)
      this.upload('linkWidth', frame.linkWidth, frame.linkCount, 1)
      this.upload('linkColor', frame.linkColor, frame.linkCount, 4)

      gl.useProgram(this.linkProg)
      gl.uniform2f(this.linkU.resolution, w, h)
      gl.uniform2f(this.linkU.camera, camera.x, camera.y)
      gl.uniform1f(this.linkU.scale, scale)
      gl.bindVertexArray(this.linkVao)
      gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, frame.linkCount)

      if (frame.arrows) {
        this.upload('linkInset', frame.linkInset, frame.linkCount, 1)
        const sizes = new Float32Array(frame.linkCount)
        sizes.fill(frame.arrowSize * dpr)
        this.upload('arrowSize', sizes, frame.linkCount, 1)

        gl.useProgram(this.arrowProg)
        gl.uniform2f(this.arrowU.resolution, w, h)
        gl.uniform2f(this.arrowU.camera, camera.x, camera.y)
        gl.uniform1f(this.arrowU.scale, scale)
        gl.bindVertexArray(this.arrowVao)
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 3, frame.linkCount)
      }
    }

    if (frame.nodeCount > 0) {
      this.upload('nodeXY', frame.nodeXY, frame.nodeCount, 2)
      this.upload('nodeRadius', frame.nodeRadius, frame.nodeCount, 1)
      this.upload('nodeColor', frame.nodeColor, frame.nodeCount, 4)
      this.upload('nodeRing', frame.nodeRing, frame.nodeCount, 1)

      gl.useProgram(this.nodeProg)
      gl.uniform2f(this.nodeU.resolution, w, h)
      gl.uniform2f(this.nodeU.camera, camera.x, camera.y)
      gl.uniform1f(this.nodeU.scale, scale)
      gl.bindVertexArray(this.nodeVao)
      gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, frame.nodeCount)
    }

    gl.bindVertexArray(null)
    void this.capacity
  }

  dispose(): void {
    const gl = this.gl
    for (const b of Object.values(this.buf)) gl.deleteBuffer(b)
    gl.deleteVertexArray(this.nodeVao)
    gl.deleteVertexArray(this.linkVao)
    gl.deleteVertexArray(this.arrowVao)
    gl.deleteProgram(this.nodeProg)
    gl.deleteProgram(this.linkProg)
    gl.deleteProgram(this.arrowProg)
  }
}

/** Allocate (or grow) the per-frame instance arrays. */
export function makeFrameData(nodes: number, links: number): FrameData {
  return {
    nodeCount: 0,
    nodeXY: new Float32Array(nodes * 2),
    nodeRadius: new Float32Array(nodes),
    nodeColor: new Float32Array(nodes * 4),
    nodeRing: new Float32Array(nodes),
    linkCount: 0,
    linkFrom: new Float32Array(links * 2),
    linkTo: new Float32Array(links * 2),
    linkWidth: new Float32Array(links),
    linkColor: new Float32Array(links * 4),
    linkInset: new Float32Array(links),
    arrows: false,
    arrowSize: 5,
  }
}
