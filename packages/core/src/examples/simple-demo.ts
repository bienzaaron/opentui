import { RGBA } from "../lib"
import { TextRenderable } from "../renderables"
import { createCliRenderer, type CliRenderer } from "../renderer"
import { getOpenTUILib } from "../zig-napi"

// export function run(renderer: CliRenderer): void {
//   renderer.start()
//   renderer.setBackgroundColor("#0d1117")
// }
//
// export function destroy(renderer: CliRenderer): void {
//   renderer.root.remove("box")
// }
//
// if (import.meta.main) {
//   const renderer = await createCliRenderer({
//     exitOnCtrlC: true,
//     targetFps: 60,
//   })
//
//   run(renderer)
// }

// TODO remove, just the minimal set to validate napi calls

const lib = getOpenTUILib()

const renderer = lib.symbols.createRenderer(100, 100, false, false)
console.log(renderer)
const buffer = lib.symbols.getNextBuffer(renderer)
const fg = RGBA.fromValues(1, 1, 1)
const bg = RGBA.fromValues(0, 0, 0)
console.log(bg.buffer)
// lib.symbols.setBackgroundColor(renderer, bg.buffer)
lib.symbols.bufferDrawChar(buffer, "A".charCodeAt(0) >>> 0, 0, 0, fg.buffer, bg.buffer, 0)
lib.symbols.render(renderer, true)

setTimeout(() => {
  lib.symbols.destroyRenderer(renderer!)
}, 5000)
