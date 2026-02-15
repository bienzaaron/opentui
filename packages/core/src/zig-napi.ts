import { type Pointer } from "bun:ffi"
import EventEmitter from "node:events"
import { createRequire } from "node:module"
import { existsSync } from "node:fs"
import { LogLevel } from "yoga-layout"
import { OptimizedBuffer } from "./buffer"
import { isBunfsPath } from "./lib/bunfs"
import { registerEnvVar } from "./lib/env"
import { RGBA } from "./lib"
import { TextBuffer } from "./text-buffer"
import { type CursorStyle, DebugOverlayCorner, type Highlight, type LineInfo, type WidthMethod } from "./types"
import type { CursorState, LogicalCursor, RenderLib, VisualCursor } from "./zig"

const module = await import(`@opentui/core-${process.platform}-${process.arch}/index.ts`)
let targetAddonPath = module.napiAddon

if (isBunfsPath(targetAddonPath)) {
  targetAddonPath = targetAddonPath.replace("../", "")
}

if (!existsSync(targetAddonPath)) {
  throw new Error(`opentui is not supported on the current platform: ${process.platform}-${process.arch}`)
}

registerEnvVar({
  name: "OTUI_DEBUG_NAPI",
  description: "Enable debug logging for the NAPI bindings.",
  type: "boolean",
  default: false,
})

registerEnvVar({
  name: "OTUI_TRACE_NAPI",
  description: "Enable tracing for the NAPI bindings.",
  type: "boolean",
  default: false,
})

type NativeLogCallback = ((level: number, message: string) => void) | null
type NativeEventCallback = ((name: string, data: ArrayBuffer) => void) | null

interface CursorStateRaw {
  x: number
  y: number
  visible: boolean
  style: number
  blinking: boolean
  r: number
  g: number
  b: number
  a: number
}

interface NapiSymbols {
  setLogCallback: (callback: NativeLogCallback) => void
  setEventCallback: (callback: NativeEventCallback) => void

  createRenderer: (width: number, height: number, testing: boolean, remote: boolean) => Pointer | null
  destroyRenderer: (renderer: Pointer) => void
  setUseThread: (renderer: Pointer, useThread: boolean) => void
  setBackgroundColor: (renderer: Pointer, color: Float32Array) => void
  setRenderOffset: (renderer: Pointer, offset: number) => void
  updateStats: (renderer: Pointer, time: number, fps: number, frameCallbackTime: number) => void
  updateMemoryStats: (renderer: Pointer, heapUsed: number, heapTotal: number, arrayBuffers: number) => void
  render: (renderer: Pointer, force: boolean) => void
  getNextBuffer: (renderer: Pointer) => Pointer | null
  getCurrentBuffer: (renderer: Pointer) => Pointer | null
  getBufferWidth: (buffer: Pointer) => number
  getBufferHeight: (buffer: Pointer) => number
  createOptimizedBuffer: (
    width: number,
    height: number,
    respectAlpha: boolean,
    widthMethod: number,
    id: string,
  ) => Pointer | null
  destroyOptimizedBuffer: (buffer: Pointer) => void
  drawFrameBuffer: (
    targetBuffer: Pointer,
    destX: number,
    destY: number,
    frameBuffer: Pointer,
    sourceX: number,
    sourceY: number,
    sourceWidth: number,
    sourceHeight: number,
  ) => void
  bufferClear: (buffer: Pointer, bg: Float32Array) => void
  bufferGetCharPtr: (buffer: Pointer) => Pointer
  bufferGetFgPtr: (buffer: Pointer) => Pointer
  bufferGetBgPtr: (buffer: Pointer) => Pointer
  bufferGetAttributesPtr: (buffer: Pointer) => Pointer
  bufferGetRespectAlpha: (buffer: Pointer) => boolean
  bufferSetRespectAlpha: (buffer: Pointer, respectAlpha: boolean) => void
  bufferGetId: (buffer: Pointer) => string
  bufferGetRealCharSize: (buffer: Pointer) => number
  bufferWriteResolvedChars: (buffer: Pointer, outputBuffer: Uint8Array, addLineBreaks: boolean) => number
  bufferDrawText: (
    buffer: Pointer,
    text: string,
    x: number,
    y: number,
    fg: Float32Array,
    bg: Float32Array | null,
    attributes: number,
  ) => void
  bufferSetCellWithAlphaBlending: (
    buffer: Pointer,
    x: number,
    y: number,
    char: number,
    fg: Float32Array,
    bg: Float32Array,
    attributes: number,
  ) => void
  bufferSetCell: (
    buffer: Pointer,
    x: number,
    y: number,
    char: number,
    fg: Float32Array,
    bg: Float32Array,
    attributes: number,
  ) => void
  bufferFillRect: (buffer: Pointer, x: number, y: number, width: number, height: number, bg: Float32Array) => void
  bufferDrawSuperSampleBuffer: (
    buffer: Pointer,
    x: number,
    y: number,
    pixelDataPtr: Pointer,
    pixelDataLength: number,
    format: number,
    alignedBytesPerRow: number,
  ) => void
  bufferDrawPackedBuffer: (
    buffer: Pointer,
    dataPtr: Pointer,
    dataLen: number,
    posX: number,
    posY: number,
    terminalWidthCells: number,
    terminalHeightCells: number,
  ) => void
  bufferDrawGrayscaleBuffer: (
    buffer: Pointer,
    posX: number,
    posY: number,
    intensitiesPtr: Pointer,
    srcWidth: number,
    srcHeight: number,
    fg: Float32Array | null,
    bg: Float32Array | null,
  ) => void
  bufferDrawGrayscaleBufferSupersampled: (
    buffer: Pointer,
    posX: number,
    posY: number,
    intensitiesPtr: Pointer,
    srcWidth: number,
    srcHeight: number,
    fg: Float32Array | null,
    bg: Float32Array | null,
  ) => void
  bufferDrawBox: (
    buffer: Pointer,
    x: number,
    y: number,
    width: number,
    height: number,
    borderChars: Uint32Array,
    packedOptions: number,
    borderColor: Float32Array,
    backgroundColor: Float32Array,
    title: string | null,
  ) => void
  bufferResize: (buffer: Pointer, width: number, height: number) => void
  bufferPushScissorRect: (buffer: Pointer, x: number, y: number, width: number, height: number) => void
  bufferPopScissorRect: (buffer: Pointer) => void
  bufferClearScissorRects: (buffer: Pointer) => void
  bufferPushOpacity: (buffer: Pointer, opacity: number) => void
  bufferPopOpacity: (buffer: Pointer) => void
  bufferGetCurrentOpacity: (buffer: Pointer) => number
  bufferClearOpacity: (buffer: Pointer) => void
  bufferDrawTextBufferView: (buffer: Pointer, view: Pointer, x: number, y: number) => void
  bufferDrawEditorView: (buffer: Pointer, view: Pointer, x: number, y: number) => void
  resizeRenderer: (renderer: Pointer, width: number, height: number) => void

  setCursorPosition: (renderer: Pointer, x: number, y: number, visible: boolean) => void
  setCursorStyle: (renderer: Pointer, style: string, blinking: boolean) => void
  setCursorColor: (renderer: Pointer, color: Float32Array) => void
  getCursorState: (renderer: Pointer) => CursorStateRaw
  setDebugOverlay: (renderer: Pointer, enabled: boolean, corner: number) => void

  clearTerminal: (renderer: Pointer) => void
  setTerminalTitle: (renderer: Pointer, title: string) => void
  copyToClipboardOSC52: (renderer: Pointer, target: number, payload: Uint8Array) => boolean
  clearClipboardOSC52: (renderer: Pointer, target: number) => boolean

  addToHitGrid: (renderer: Pointer, x: number, y: number, width: number, height: number, id: number) => void
  clearCurrentHitGrid: (renderer: Pointer) => void
  hitGridPushScissorRect: (renderer: Pointer, x: number, y: number, width: number, height: number) => void
  hitGridPopScissorRect: (renderer: Pointer) => void
  hitGridClearScissorRects: (renderer: Pointer) => void
  addToCurrentHitGridClipped: (
    renderer: Pointer,
    x: number,
    y: number,
    width: number,
    height: number,
    id: number,
  ) => void
  checkHit: (renderer: Pointer, x: number, y: number) => number
  getHitGridDirty: (renderer: Pointer) => boolean
  dumpHitGrid: (renderer: Pointer) => void
  dumpBuffers: (renderer: Pointer, timestamp: number) => void
  dumpStdoutBuffer: (renderer: Pointer, timestamp: number) => void
  enableMouse: (renderer: Pointer, enableMovement: boolean) => void
  disableMouse: (renderer: Pointer) => void
  enableKittyKeyboard: (renderer: Pointer, flags: number) => void
  disableKittyKeyboard: (renderer: Pointer) => void
  setKittyKeyboardFlags: (renderer: Pointer, flags: number) => void
  getKittyKeyboardFlags: (renderer: Pointer) => number

  setupTerminal: (renderer: Pointer, useAlternateScreen: boolean) => void
  suspendRenderer: (renderer: Pointer) => void
  resumeRenderer: (renderer: Pointer) => void
  queryPixelResolution: (renderer: Pointer) => void
  writeOut: (renderer: Pointer, data: Uint8Array) => void

  bufferDrawChar: (
    buffer: Pointer,
    char: number,
    x: number,
    y: number,
    fg: Float32Array,
    bg: Float32Array,
    attributes: number,
  ) => void

  createTextBuffer: (widthMethod: number) => Pointer | null
  destroyTextBuffer: (buffer: Pointer) => void
  textBufferGetLength: (buffer: Pointer) => number
  textBufferGetByteSize: (buffer: Pointer) => number
  textBufferReset: (buffer: Pointer) => void
  textBufferClear: (buffer: Pointer) => void
  textBufferSetDefaultFg: (buffer: Pointer, fg: Float32Array | null) => void
  textBufferSetDefaultBg: (buffer: Pointer, bg: Float32Array | null) => void
  textBufferSetDefaultAttributes: (buffer: Pointer, attributes: number | null) => void
  textBufferResetDefaults: (buffer: Pointer) => void
  textBufferGetTabWidth: (buffer: Pointer) => number
  textBufferSetTabWidth: (buffer: Pointer, width: number) => void
  textBufferRegisterMemBuffer: (buffer: Pointer, bytes: Uint8Array, owned: boolean) => number
  textBufferReplaceMemBuffer: (buffer: Pointer, memId: number, bytes: Uint8Array, owned: boolean) => boolean
  textBufferClearMemRegistry: (buffer: Pointer) => void
  textBufferSetTextFromMem: (buffer: Pointer, memId: number) => void
  textBufferAppend: (buffer: Pointer, bytes: Uint8Array) => void
  textBufferAppendFromMemId: (buffer: Pointer, memId: number) => void
  textBufferLoadFile: (buffer: Pointer, path: string) => boolean
  textBufferSetStyledText: (
    buffer: Pointer,
    chunks: Array<{ text: string; fg?: RGBA | null; bg?: RGBA | null; attributes?: number; link?: { url: string } }>,
  ) => void
  textBufferGetLineCount: (buffer: Pointer) => number
  textBufferGetPlainTextBytes: (buffer: Pointer, maxLength: number) => ArrayBuffer | null
  textBufferGetTextRange: (
    buffer: Pointer,
    startOffset: number,
    endOffset: number,
    maxLength: number,
  ) => ArrayBuffer | null
  textBufferGetTextRangeByCoords: (
    buffer: Pointer,
    startRow: number,
    startCol: number,
    endRow: number,
    endCol: number,
    maxLength: number,
  ) => ArrayBuffer | null
  createTextBufferView: (textBuffer: Pointer) => Pointer | null
  destroyTextBufferView: (view: Pointer) => void
  textBufferViewSetSelection: (
    view: Pointer,
    start: number,
    end: number,
    bgColor: Float32Array | null,
    fgColor: Float32Array | null,
  ) => void
  textBufferViewResetSelection: (view: Pointer) => void
  textBufferViewGetSelection: (view: Pointer) => { start: number; end: number } | null
  textBufferViewSetLocalSelection: (
    view: Pointer,
    anchorX: number,
    anchorY: number,
    focusX: number,
    focusY: number,
    bgColor: Float32Array | null,
    fgColor: Float32Array | null,
  ) => boolean
  textBufferViewUpdateSelection: (
    view: Pointer,
    end: number,
    bgColor: Float32Array | null,
    fgColor: Float32Array | null,
  ) => void
  textBufferViewUpdateLocalSelection: (
    view: Pointer,
    anchorX: number,
    anchorY: number,
    focusX: number,
    focusY: number,
    bgColor: Float32Array | null,
    fgColor: Float32Array | null,
  ) => boolean
  textBufferViewResetLocalSelection: (view: Pointer) => void
  textBufferViewSetWrapWidth: (view: Pointer, width: number) => void
  textBufferViewSetWrapMode: (view: Pointer, mode: number) => void
  textBufferViewSetViewportSize: (view: Pointer, width: number, height: number) => void
  textBufferViewSetViewport: (view: Pointer, x: number, y: number, width: number, height: number) => void
  textBufferViewGetVirtualLineCount: (view: Pointer) => number
  textBufferViewGetLineInfo: (view: Pointer) => LineInfo
  textBufferViewGetLogicalLineInfo: (view: Pointer) => LineInfo
  textBufferViewGetSelectedTextBytes: (view: Pointer, maxLength: number) => ArrayBuffer | null
  textBufferViewGetPlainTextBytes: (view: Pointer, maxLength: number) => ArrayBuffer | null
  textBufferViewSetTabIndicator: (view: Pointer, indicator: number) => void
  textBufferViewSetTabIndicatorColor: (view: Pointer, color: Float32Array) => void
  textBufferViewSetTruncate: (view: Pointer, truncate: boolean) => void
  textBufferViewMeasureForDimensions: (
    view: Pointer,
    width: number,
    height: number,
  ) => { lineCount: number; maxWidth: number } | null
  textBufferAddHighlightByCharRange: (buffer: Pointer, highlight: Highlight) => void
  textBufferAddHighlight: (buffer: Pointer, lineIdx: number, highlight: Highlight) => void
  textBufferRemoveHighlightsByRef: (buffer: Pointer, hlRef: number) => void
  textBufferClearLineHighlights: (buffer: Pointer, lineIdx: number) => void
  textBufferClearAllHighlights: (buffer: Pointer) => void
  textBufferSetSyntaxStyle: (buffer: Pointer, style: Pointer | null) => void
  textBufferGetLineHighlights: (buffer: Pointer, lineIdx: number) => Highlight[]
  textBufferGetHighlightCount: (buffer: Pointer) => number
}

const REQUIRED_SYMBOLS = [
  "setLogCallback",
  "setEventCallback",
  "createRenderer",
  "destroyRenderer",
  "setUseThread",
  "setBackgroundColor",
  "setRenderOffset",
  "updateStats",
  "updateMemoryStats",
  "render",
  "getNextBuffer",
  "getCurrentBuffer",
  "getBufferWidth",
  "getBufferHeight",
  "createOptimizedBuffer",
  "destroyOptimizedBuffer",
  "drawFrameBuffer",
  "bufferClear",
  "bufferGetCharPtr",
  "bufferGetFgPtr",
  "bufferGetBgPtr",
  "bufferGetAttributesPtr",
  "bufferGetRespectAlpha",
  "bufferSetRespectAlpha",
  "bufferGetId",
  "bufferGetRealCharSize",
  "bufferWriteResolvedChars",
  "bufferDrawText",
  "bufferSetCellWithAlphaBlending",
  "bufferSetCell",
  "bufferFillRect",
  "bufferDrawSuperSampleBuffer",
  "bufferDrawPackedBuffer",
  "bufferDrawGrayscaleBuffer",
  "bufferDrawGrayscaleBufferSupersampled",
  "bufferDrawBox",
  "bufferResize",
  "bufferPushScissorRect",
  "bufferPopScissorRect",
  "bufferClearScissorRects",
  "bufferPushOpacity",
  "bufferPopOpacity",
  "bufferGetCurrentOpacity",
  "bufferClearOpacity",
  "bufferDrawTextBufferView",
  "bufferDrawEditorView",
  "resizeRenderer",
  "setCursorPosition",
  "setCursorStyle",
  "setCursorColor",
  "getCursorState",
  "setDebugOverlay",
  "clearTerminal",
  "setTerminalTitle",
  "copyToClipboardOSC52",
  "clearClipboardOSC52",
  "addToHitGrid",
  "clearCurrentHitGrid",
  "hitGridPushScissorRect",
  "hitGridPopScissorRect",
  "hitGridClearScissorRects",
  "addToCurrentHitGridClipped",
  "checkHit",
  "getHitGridDirty",
  "dumpHitGrid",
  "dumpBuffers",
  "dumpStdoutBuffer",
  "enableMouse",
  "disableMouse",
  "enableKittyKeyboard",
  "disableKittyKeyboard",
  "setKittyKeyboardFlags",
  "getKittyKeyboardFlags",
  "setupTerminal",
  "suspendRenderer",
  "resumeRenderer",
  "queryPixelResolution",
  "writeOut",
  "bufferDrawChar",
  "createTextBuffer",
  "destroyTextBuffer",
  "textBufferGetLength",
  "textBufferGetByteSize",
  "textBufferReset",
  "textBufferClear",
  "textBufferSetDefaultFg",
  "textBufferSetDefaultBg",
  "textBufferSetDefaultAttributes",
  "textBufferResetDefaults",
  "textBufferGetTabWidth",
  "textBufferSetTabWidth",
  "textBufferRegisterMemBuffer",
  "textBufferReplaceMemBuffer",
  "textBufferClearMemRegistry",
  "textBufferSetTextFromMem",
  "textBufferAppend",
  "textBufferAppendFromMemId",
  "textBufferLoadFile",
  "textBufferSetStyledText",
  "textBufferGetLineCount",
  "textBufferGetPlainTextBytes",
  "textBufferGetTextRange",
  "textBufferGetTextRangeByCoords",
  "createTextBufferView",
  "destroyTextBufferView",
  "textBufferViewSetSelection",
  "textBufferViewResetSelection",
  "textBufferViewGetSelection",
  "textBufferViewSetLocalSelection",
  "textBufferViewUpdateSelection",
  "textBufferViewUpdateLocalSelection",
  "textBufferViewResetLocalSelection",
  "textBufferViewSetWrapWidth",
  "textBufferViewSetWrapMode",
  "textBufferViewSetViewportSize",
  "textBufferViewSetViewport",
  "textBufferViewGetVirtualLineCount",
  "textBufferViewGetLineInfo",
  "textBufferViewGetLogicalLineInfo",
  "textBufferViewGetSelectedTextBytes",
  "textBufferViewGetPlainTextBytes",
  "textBufferViewSetTabIndicator",
  "textBufferViewSetTabIndicatorColor",
  "textBufferViewSetTruncate",
  "textBufferViewMeasureForDimensions",
  "textBufferAddHighlightByCharRange",
  "textBufferAddHighlight",
  "textBufferRemoveHighlightsByRef",
  "textBufferClearLineHighlights",
  "textBufferClearAllHighlights",
  "textBufferSetSyntaxStyle",
  "textBufferGetLineHighlights",
  "textBufferGetHighlightCount",
] as const

function assertSymbols(raw: unknown): asserts raw is NapiSymbols {
  if (!raw || typeof raw !== "object") {
    throw new Error("OpenTUI Node-API addon exports are invalid")
  }

  for (const symbol of REQUIRED_SYMBOLS) {
    if (typeof (raw as Record<string, unknown>)[symbol] !== "function") {
      throw new Error(`OpenTUI Node-API addon is missing required symbol: ${symbol}`)
    }
  }
}

type OpenTUILib = { symbols: NapiSymbols }

function normalizePointer(pointer: Pointer): Pointer {
  return (typeof pointer === "bigint" ? Number(pointer) : pointer) as Pointer
}

export function getOpenTUILib(libPath?: string): OpenTUILib {
  const resolvedAddonPath = libPath || targetAddonPath
  if (!existsSync(resolvedAddonPath)) {
    throw new Error(`OpenTUI Node-API addon not found at ${resolvedAddonPath}`)
  }

  const require = createRequire(import.meta.url)
  const addon: unknown = require(resolvedAddonPath)
  assertSymbols(addon)
  return { symbols: addon }
}

export class NapiRenderLib implements RenderLib {
  private opentui: OpenTUILib
  public readonly encoder: TextEncoder = new TextEncoder()
  public readonly decoder: TextDecoder = new TextDecoder()
  private _nativeEvents: EventEmitter = new EventEmitter()
  private _anyEventHandlers: Array<(name: string, data: ArrayBuffer) => void> = []

  constructor(libPath?: string) {
    this.opentui = getOpenTUILib(libPath)
    this.setupLogging()
    this.setupEventBus()
  }

  private setupLogging() {
    const logCallback = (level: number, message: string) => {
      switch (level) {
        case LogLevel.Error:
          console.error(message)
          break
        case LogLevel.Warn:
          console.warn(message)
          break
        case LogLevel.Info:
          console.info(message)
          break
        case LogLevel.Debug:
          console.debug(message)
          break
        default:
          console.log(message)
      }
    }
    this.setLogCallback(logCallback)
  }

  private setLogCallback(callback: NativeLogCallback) {
    this.opentui.symbols.setLogCallback(callback)
  }

  private setupEventBus() {
    const eventCallback = (eventName: string, eventData: ArrayBuffer) => {
      queueMicrotask(() => {
        this._nativeEvents.emit(eventName, eventData)
        for (const handler of this._anyEventHandlers) {
          handler(eventName, eventData)
        }
      })
    }
    this.setEventCallback(eventCallback)
  }

  private setEventCallback(callback: NativeEventCallback) {
    this.opentui.symbols.setEventCallback(callback)
  }

  public createRenderer(width: number, height: number, options: { testing?: boolean; remote?: boolean } = {}) {
    const testing = options.testing ?? false
    const remote = options.remote ?? false
    return this.opentui.symbols.createRenderer(width, height, testing, remote)
  }

  public destroyRenderer(renderer: Pointer): void {
    this.opentui.symbols.destroyRenderer(renderer)
  }

  public setUseThread(renderer: Pointer, useThread: boolean): void {
    this.opentui.symbols.setUseThread(renderer, useThread)
  }

  public setBackgroundColor(renderer: Pointer, color: RGBA): void {
    this.opentui.symbols.setBackgroundColor(renderer, color.buffer)
  }

  public setRenderOffset(renderer: Pointer, offset: number): void {
    this.opentui.symbols.setRenderOffset(renderer, offset)
  }

  public updateStats(renderer: Pointer, time: number, fps: number, frameCallbackTime: number): void {
    this.opentui.symbols.updateStats(renderer, time, fps, frameCallbackTime)
  }

  public updateMemoryStats(renderer: Pointer, heapUsed: number, heapTotal: number, arrayBuffers: number): void {
    this.opentui.symbols.updateMemoryStats(renderer, heapUsed, heapTotal, arrayBuffers)
  }

  public render(renderer: Pointer, force: boolean): void {
    this.opentui.symbols.render(renderer, force)
  }

  public getNextBuffer(renderer: Pointer): OptimizedBuffer {
    const bufferPtr = this.opentui.symbols.getNextBuffer(renderer)
    if (!bufferPtr) {
      throw new Error("Failed to get next buffer")
    }

    const width = this.opentui.symbols.getBufferWidth(bufferPtr)
    const height = this.opentui.symbols.getBufferHeight(bufferPtr)
    return new OptimizedBuffer(this, bufferPtr, width, height, { id: "next buffer", widthMethod: "unicode" })
  }

  public getCurrentBuffer(renderer: Pointer): OptimizedBuffer {
    const bufferPtr = this.opentui.symbols.getCurrentBuffer(renderer)
    if (!bufferPtr) {
      throw new Error("Failed to get current buffer")
    }

    const width = this.opentui.symbols.getBufferWidth(bufferPtr)
    const height = this.opentui.symbols.getBufferHeight(bufferPtr)
    return new OptimizedBuffer(this, bufferPtr, width, height, { id: "current buffer", widthMethod: "unicode" })
  }

  public getBufferWidth(buffer: Pointer): number {
    return this.opentui.symbols.getBufferWidth(buffer)
  }

  public getBufferHeight(buffer: Pointer): number {
    return this.opentui.symbols.getBufferHeight(buffer)
  }

  public resizeRenderer(renderer: Pointer, width: number, height: number): void {
    this.opentui.symbols.resizeRenderer(renderer, width, height)
  }

  public setCursorPosition(renderer: Pointer, x: number, y: number, visible: boolean): void {
    this.opentui.symbols.setCursorPosition(renderer, x, y, visible)
  }

  public setCursorStyle(renderer: Pointer, style: CursorStyle, blinking: boolean): void {
    this.opentui.symbols.setCursorStyle(renderer, style, blinking)
  }

  public setCursorColor(renderer: Pointer, color: RGBA): void {
    this.opentui.symbols.setCursorColor(renderer, color.buffer)
  }

  public getCursorState(renderer: Pointer): CursorState {
    const raw = this.opentui.symbols.getCursorState(renderer)
    const styleMap: Record<number, CursorStyle> = {
      0: "block",
      1: "line",
      2: "underline",
    }

    return {
      x: raw.x,
      y: raw.y,
      visible: raw.visible,
      style: styleMap[raw.style] || "block",
      blinking: raw.blinking,
      color: RGBA.fromValues(raw.r, raw.g, raw.b, raw.a),
    }
  }

  public setDebugOverlay(renderer: Pointer, enabled: boolean, corner: DebugOverlayCorner): void {
    this.opentui.symbols.setDebugOverlay(renderer, enabled, corner)
  }

  public clearTerminal(renderer: Pointer): void {
    this.opentui.symbols.clearTerminal(renderer)
  }

  public setTerminalTitle(renderer: Pointer, title: string): void {
    this.opentui.symbols.setTerminalTitle(renderer, title)
  }

  public copyToClipboardOSC52(renderer: Pointer, target: number, payload: Uint8Array): boolean {
    return this.opentui.symbols.copyToClipboardOSC52(renderer, target, payload)
  }

  public clearClipboardOSC52(renderer: Pointer, target: number): boolean {
    return this.opentui.symbols.clearClipboardOSC52(renderer, target)
  }

  public addToHitGrid(renderer: Pointer, x: number, y: number, width: number, height: number, id: number): void {
    this.opentui.symbols.addToHitGrid(renderer, x, y, width, height, id)
  }

  public clearCurrentHitGrid(renderer: Pointer): void {
    this.opentui.symbols.clearCurrentHitGrid(renderer)
  }

  public hitGridPushScissorRect(renderer: Pointer, x: number, y: number, width: number, height: number): void {
    this.opentui.symbols.hitGridPushScissorRect(renderer, x, y, width, height)
  }

  public hitGridPopScissorRect(renderer: Pointer): void {
    this.opentui.symbols.hitGridPopScissorRect(renderer)
  }

  public hitGridClearScissorRects(renderer: Pointer): void {
    this.opentui.symbols.hitGridClearScissorRects(renderer)
  }

  public addToCurrentHitGridClipped(
    renderer: Pointer,
    x: number,
    y: number,
    width: number,
    height: number,
    id: number,
  ): void {
    this.opentui.symbols.addToCurrentHitGridClipped(renderer, x, y, width, height, id)
  }

  public checkHit(renderer: Pointer, x: number, y: number): number {
    return this.opentui.symbols.checkHit(renderer, x, y)
  }

  public getHitGridDirty(renderer: Pointer): boolean {
    return this.opentui.symbols.getHitGridDirty(renderer)
  }

  public dumpHitGrid(renderer: Pointer): void {
    this.opentui.symbols.dumpHitGrid(renderer)
  }

  public dumpBuffers(renderer: Pointer, timestamp?: number): void {
    const ts = timestamp ?? Date.now()
    this.opentui.symbols.dumpBuffers(renderer, ts)
  }

  public dumpStdoutBuffer(renderer: Pointer, timestamp?: number): void {
    const ts = timestamp ?? Date.now()
    this.opentui.symbols.dumpStdoutBuffer(renderer, ts)
  }

  public enableMouse(renderer: Pointer, enableMovement: boolean): void {
    this.opentui.symbols.enableMouse(renderer, enableMovement)
  }

  public disableMouse(renderer: Pointer): void {
    this.opentui.symbols.disableMouse(renderer)
  }

  public enableKittyKeyboard(renderer: Pointer, flags: number): void {
    this.opentui.symbols.enableKittyKeyboard(renderer, flags)
  }

  public disableKittyKeyboard(renderer: Pointer): void {
    this.opentui.symbols.disableKittyKeyboard(renderer)
  }

  public setKittyKeyboardFlags(renderer: Pointer, flags: number): void {
    this.opentui.symbols.setKittyKeyboardFlags(renderer, flags)
  }

  public getKittyKeyboardFlags(renderer: Pointer): number {
    return this.opentui.symbols.getKittyKeyboardFlags(renderer)
  }

  public setupTerminal(renderer: Pointer, useAlternateScreen: boolean): void {
    this.opentui.symbols.setupTerminal(renderer, useAlternateScreen)
  }

  public suspendRenderer(renderer: Pointer): void {
    this.opentui.symbols.suspendRenderer(renderer)
  }

  public resumeRenderer(renderer: Pointer): void {
    this.opentui.symbols.resumeRenderer(renderer)
  }

  public queryPixelResolution(renderer: Pointer): void {
    this.opentui.symbols.queryPixelResolution(renderer)
  }

  public writeOut(renderer: Pointer, data: string | Uint8Array): void {
    const bytes = typeof data === "string" ? this.encoder.encode(data) : data
    this.opentui.symbols.writeOut(renderer, bytes)
  }

  public bufferDrawChar(
    buffer: Pointer,
    char: number,
    x: number,
    y: number,
    fg: RGBA,
    bg: RGBA,
    attributes: number = 0,
  ) {
    this.opentui.symbols.bufferDrawChar(buffer, char, x, y, fg.buffer, bg.buffer, attributes)
  }

  public createOptimizedBuffer(
    width: number,
    height: number,
    widthMethod: WidthMethod,
    respectAlpha: boolean = false,
    id?: string,
  ): OptimizedBuffer {
    if (Number.isNaN(width) || Number.isNaN(height)) {
      console.error(new Error(`Invalid dimensions for OptimizedBuffer: ${width}x${height}`).stack)
    }

    const widthMethodCode = widthMethod === "wcwidth" ? 0 : 1
    const idToUse = id || "unnamed buffer"
    const bufferPtr = this.opentui.symbols.createOptimizedBuffer(width, height, respectAlpha, widthMethodCode, idToUse)
    if (!bufferPtr) {
      throw new Error(`Failed to create optimized buffer: ${width}x${height}`)
    }

    return new OptimizedBuffer(this, bufferPtr, width, height, { respectAlpha, id, widthMethod })
  }

  public destroyOptimizedBuffer(bufferPtr: Pointer): void {
    this.opentui.symbols.destroyOptimizedBuffer(bufferPtr)
  }

  public drawFrameBuffer(
    targetBufferPtr: Pointer,
    destX: number,
    destY: number,
    bufferPtr: Pointer,
    sourceX?: number,
    sourceY?: number,
    sourceWidth?: number,
    sourceHeight?: number,
  ): void {
    const srcX = sourceX ?? 0
    const srcY = sourceY ?? 0
    const srcWidth = sourceWidth ?? 0
    const srcHeight = sourceHeight ?? 0
    this.opentui.symbols.drawFrameBuffer(targetBufferPtr, destX, destY, bufferPtr, srcX, srcY, srcWidth, srcHeight)
  }

  public bufferClear(buffer: Pointer, color: RGBA): void {
    this.opentui.symbols.bufferClear(buffer, color.buffer)
  }

  public bufferGetCharPtr(buffer: Pointer): Pointer {
    const ptr = this.opentui.symbols.bufferGetCharPtr(buffer)
    if (!ptr) throw new Error("Failed to get char pointer")
    return ptr
  }

  public bufferGetFgPtr(buffer: Pointer): Pointer {
    const ptr = this.opentui.symbols.bufferGetFgPtr(buffer)
    if (!ptr) throw new Error("Failed to get fg pointer")
    return ptr
  }

  public bufferGetBgPtr(buffer: Pointer): Pointer {
    const ptr = this.opentui.symbols.bufferGetBgPtr(buffer)
    if (!ptr) throw new Error("Failed to get bg pointer")
    return ptr
  }

  public bufferGetAttributesPtr(buffer: Pointer): Pointer {
    const ptr = this.opentui.symbols.bufferGetAttributesPtr(buffer)
    if (!ptr) throw new Error("Failed to get attributes pointer")
    return ptr
  }

  public bufferGetRespectAlpha(buffer: Pointer): boolean {
    return this.opentui.symbols.bufferGetRespectAlpha(buffer)
  }

  public bufferSetRespectAlpha(buffer: Pointer, respectAlpha: boolean): void {
    this.opentui.symbols.bufferSetRespectAlpha(buffer, respectAlpha)
  }

  public bufferGetId(buffer: Pointer): string {
    return this.opentui.symbols.bufferGetId(buffer)
  }

  public bufferGetRealCharSize(buffer: Pointer): number {
    return this.opentui.symbols.bufferGetRealCharSize(buffer)
  }

  public bufferWriteResolvedChars(buffer: Pointer, outputBuffer: Uint8Array, addLineBreaks: boolean): number {
    return this.opentui.symbols.bufferWriteResolvedChars(buffer, outputBuffer, addLineBreaks)
  }

  public bufferDrawText(
    buffer: Pointer,
    text: string,
    x: number,
    y: number,
    color: RGBA,
    bgColor?: RGBA,
    attributes?: number,
  ): void {
    this.opentui.symbols.bufferDrawText(buffer, text, x, y, color.buffer, bgColor?.buffer ?? null, attributes ?? 0)
  }

  public bufferSetCellWithAlphaBlending(
    buffer: Pointer,
    x: number,
    y: number,
    char: string,
    color: RGBA,
    bgColor: RGBA,
    attributes?: number,
  ): void {
    const charCode = char.codePointAt(0) ?? " ".codePointAt(0)!
    this.opentui.symbols.bufferSetCellWithAlphaBlending(
      buffer,
      x,
      y,
      charCode,
      color.buffer,
      bgColor.buffer,
      attributes ?? 0,
    )
  }

  public bufferSetCell(
    buffer: Pointer,
    x: number,
    y: number,
    char: string,
    color: RGBA,
    bgColor: RGBA,
    attributes?: number,
  ): void {
    const charCode = char.codePointAt(0) ?? " ".codePointAt(0)!
    this.opentui.symbols.bufferSetCell(buffer, x, y, charCode, color.buffer, bgColor.buffer, attributes ?? 0)
  }

  public bufferFillRect(buffer: Pointer, x: number, y: number, width: number, height: number, color: RGBA): void {
    this.opentui.symbols.bufferFillRect(buffer, x, y, width, height, color.buffer)
  }

  public bufferDrawSuperSampleBuffer(
    buffer: Pointer,
    x: number,
    y: number,
    pixelDataPtr: Pointer,
    pixelDataLength: number,
    format: "bgra8unorm" | "rgba8unorm",
    alignedBytesPerRow: number,
  ): void {
    const formatId = format === "bgra8unorm" ? 0 : 1
    this.opentui.symbols.bufferDrawSuperSampleBuffer(
      buffer,
      x,
      y,
      normalizePointer(pixelDataPtr),
      pixelDataLength,
      formatId,
      alignedBytesPerRow,
    )
  }

  public bufferDrawPackedBuffer(
    buffer: Pointer,
    dataPtr: Pointer,
    dataLen: number,
    posX: number,
    posY: number,
    terminalWidthCells: number,
    terminalHeightCells: number,
  ): void {
    this.opentui.symbols.bufferDrawPackedBuffer(
      buffer,
      normalizePointer(dataPtr),
      dataLen,
      posX,
      posY,
      terminalWidthCells,
      terminalHeightCells,
    )
  }

  public bufferDrawGrayscaleBuffer(
    buffer: Pointer,
    posX: number,
    posY: number,
    intensitiesPtr: Pointer,
    srcWidth: number,
    srcHeight: number,
    fg: RGBA | null,
    bg: RGBA | null,
  ): void {
    this.opentui.symbols.bufferDrawGrayscaleBuffer(
      buffer,
      posX,
      posY,
      normalizePointer(intensitiesPtr),
      srcWidth,
      srcHeight,
      fg?.buffer ?? null,
      bg?.buffer ?? null,
    )
  }

  public bufferDrawGrayscaleBufferSupersampled(
    buffer: Pointer,
    posX: number,
    posY: number,
    intensitiesPtr: Pointer,
    srcWidth: number,
    srcHeight: number,
    fg: RGBA | null,
    bg: RGBA | null,
  ): void {
    this.opentui.symbols.bufferDrawGrayscaleBufferSupersampled(
      buffer,
      posX,
      posY,
      normalizePointer(intensitiesPtr),
      srcWidth,
      srcHeight,
      fg?.buffer ?? null,
      bg?.buffer ?? null,
    )
  }

  public bufferDrawBox(
    buffer: Pointer,
    x: number,
    y: number,
    width: number,
    height: number,
    borderChars: Uint32Array,
    packedOptions: number,
    borderColor: RGBA,
    backgroundColor: RGBA,
    title: string | null,
  ): void {
    this.opentui.symbols.bufferDrawBox(
      buffer,
      x,
      y,
      width,
      height,
      borderChars,
      packedOptions,
      borderColor.buffer,
      backgroundColor.buffer,
      title,
    )
  }

  public bufferResize(buffer: Pointer, width: number, height: number): void {
    this.opentui.symbols.bufferResize(buffer, width, height)
  }

  public bufferPushScissorRect(buffer: Pointer, x: number, y: number, width: number, height: number): void {
    this.opentui.symbols.bufferPushScissorRect(buffer, x, y, width, height)
  }

  public bufferPopScissorRect(buffer: Pointer): void {
    this.opentui.symbols.bufferPopScissorRect(buffer)
  }

  public bufferClearScissorRects(buffer: Pointer): void {
    this.opentui.symbols.bufferClearScissorRects(buffer)
  }

  public bufferPushOpacity(buffer: Pointer, opacity: number): void {
    this.opentui.symbols.bufferPushOpacity(buffer, opacity)
  }

  public bufferPopOpacity(buffer: Pointer): void {
    this.opentui.symbols.bufferPopOpacity(buffer)
  }

  public bufferGetCurrentOpacity(buffer: Pointer): number {
    return this.opentui.symbols.bufferGetCurrentOpacity(buffer)
  }

  public bufferClearOpacity(buffer: Pointer): void {
    this.opentui.symbols.bufferClearOpacity(buffer)
  }

  public bufferDrawTextBufferView(buffer: Pointer, view: Pointer, x: number, y: number): void {
    this.opentui.symbols.bufferDrawTextBufferView(buffer, view, x, y)
  }

  public bufferDrawEditorView(buffer: Pointer, view: Pointer, x: number, y: number): void {
    this.opentui.symbols.bufferDrawEditorView(buffer, view, x, y)
  }

  public createTextBuffer(widthMethod: WidthMethod): TextBuffer {
    const widthMethodCode = widthMethod === "wcwidth" ? 0 : 1
    const bufferPtr = this.opentui.symbols.createTextBuffer(widthMethodCode)
    if (!bufferPtr) {
      throw new Error("Failed to create TextBuffer")
    }
    return new TextBuffer(this, bufferPtr)
  }

  public destroyTextBuffer(buffer: Pointer): void {
    this.opentui.symbols.destroyTextBuffer(buffer)
  }

  public textBufferGetLength(buffer: Pointer): number {
    return this.opentui.symbols.textBufferGetLength(buffer)
  }

  public textBufferGetByteSize(buffer: Pointer): number {
    return this.opentui.symbols.textBufferGetByteSize(buffer)
  }

  public textBufferReset(buffer: Pointer): void {
    this.opentui.symbols.textBufferReset(buffer)
  }

  public textBufferClear(buffer: Pointer): void {
    this.opentui.symbols.textBufferClear(buffer)
  }

  public textBufferRegisterMemBuffer(buffer: Pointer, bytes: Uint8Array, owned: boolean = false): number {
    const result = this.opentui.symbols.textBufferRegisterMemBuffer(buffer, bytes, owned)
    if (result === 0xffff) {
      throw new Error("Failed to register memory buffer")
    }
    return result
  }

  public textBufferReplaceMemBuffer(
    buffer: Pointer,
    memId: number,
    bytes: Uint8Array,
    owned: boolean = false,
  ): boolean {
    return this.opentui.symbols.textBufferReplaceMemBuffer(buffer, memId, bytes, owned)
  }

  public textBufferClearMemRegistry(buffer: Pointer): void {
    this.opentui.symbols.textBufferClearMemRegistry(buffer)
  }

  public textBufferSetTextFromMem(buffer: Pointer, memId: number): void {
    this.opentui.symbols.textBufferSetTextFromMem(buffer, memId)
  }

  public textBufferAppend(buffer: Pointer, bytes: Uint8Array): void {
    this.opentui.symbols.textBufferAppend(buffer, bytes)
  }

  public textBufferAppendFromMemId(buffer: Pointer, memId: number): void {
    this.opentui.symbols.textBufferAppendFromMemId(buffer, memId)
  }

  public textBufferLoadFile(buffer: Pointer, path: string): boolean {
    return this.opentui.symbols.textBufferLoadFile(buffer, path)
  }

  public textBufferSetStyledText(
    buffer: Pointer,
    chunks: Array<{ text: string; fg?: RGBA | null; bg?: RGBA | null; attributes?: number; link?: { url: string } }>,
  ): void {
    const nonEmptyChunks = chunks.filter((chunk) => chunk.text.length > 0)
    if (nonEmptyChunks.length === 0) {
      this.textBufferClear(buffer)
      return
    }
    this.opentui.symbols.textBufferSetStyledText(buffer, nonEmptyChunks)
  }

  public textBufferSetDefaultFg(buffer: Pointer, fg: RGBA | null): void {
    this.opentui.symbols.textBufferSetDefaultFg(buffer, fg?.buffer ?? null)
  }

  public textBufferSetDefaultBg(buffer: Pointer, bg: RGBA | null): void {
    this.opentui.symbols.textBufferSetDefaultBg(buffer, bg?.buffer ?? null)
  }

  public textBufferSetDefaultAttributes(buffer: Pointer, attributes: number | null): void {
    this.opentui.symbols.textBufferSetDefaultAttributes(buffer, attributes)
  }

  public textBufferResetDefaults(buffer: Pointer): void {
    this.opentui.symbols.textBufferResetDefaults(buffer)
  }

  public textBufferGetTabWidth(buffer: Pointer): number {
    return this.opentui.symbols.textBufferGetTabWidth(buffer)
  }

  public textBufferSetTabWidth(buffer: Pointer, width: number): void {
    this.opentui.symbols.textBufferSetTabWidth(buffer, width)
  }

  public textBufferGetLineCount(buffer: Pointer): number {
    return this.opentui.symbols.textBufferGetLineCount(buffer)
  }

  public getPlainTextBytes(buffer: Pointer, maxLength: number): Uint8Array | null {
    const raw = this.opentui.symbols.textBufferGetPlainTextBytes(buffer, maxLength)
    return raw ? new Uint8Array(raw) : null
  }

  public textBufferGetTextRange(
    buffer: Pointer,
    startOffset: number,
    endOffset: number,
    maxLength: number,
  ): Uint8Array | null {
    const raw = this.opentui.symbols.textBufferGetTextRange(buffer, startOffset, endOffset, maxLength)
    return raw ? new Uint8Array(raw) : null
  }

  public textBufferGetTextRangeByCoords(
    buffer: Pointer,
    startRow: number,
    startCol: number,
    endRow: number,
    endCol: number,
    maxLength: number,
  ): Uint8Array | null {
    const raw = this.opentui.symbols.textBufferGetTextRangeByCoords(
      buffer,
      startRow,
      startCol,
      endRow,
      endCol,
      maxLength,
    )
    return raw ? new Uint8Array(raw) : null
  }

  public createTextBufferView(textBuffer: Pointer): Pointer {
    const viewPtr = this.opentui.symbols.createTextBufferView(textBuffer)
    if (!viewPtr) {
      throw new Error("Failed to create TextBufferView")
    }
    return viewPtr
  }

  public destroyTextBufferView(view: Pointer): void {
    this.opentui.symbols.destroyTextBufferView(view)
  }

  public textBufferViewSetSelection(
    view: Pointer,
    start: number,
    end: number,
    bgColor: RGBA | null,
    fgColor: RGBA | null,
  ): void {
    this.opentui.symbols.textBufferViewSetSelection(view, start, end, bgColor?.buffer ?? null, fgColor?.buffer ?? null)
  }

  public textBufferViewResetSelection(view: Pointer): void {
    this.opentui.symbols.textBufferViewResetSelection(view)
  }

  public textBufferViewGetSelection(view: Pointer): { start: number; end: number } | null {
    return this.opentui.symbols.textBufferViewGetSelection(view)
  }

  public textBufferViewSetLocalSelection(
    view: Pointer,
    anchorX: number,
    anchorY: number,
    focusX: number,
    focusY: number,
    bgColor: RGBA | null,
    fgColor: RGBA | null,
  ): boolean {
    return this.opentui.symbols.textBufferViewSetLocalSelection(
      view,
      anchorX,
      anchorY,
      focusX,
      focusY,
      bgColor?.buffer ?? null,
      fgColor?.buffer ?? null,
    )
  }

  public textBufferViewUpdateSelection(view: Pointer, end: number, bgColor: RGBA | null, fgColor: RGBA | null): void {
    this.opentui.symbols.textBufferViewUpdateSelection(view, end, bgColor?.buffer ?? null, fgColor?.buffer ?? null)
  }

  public textBufferViewUpdateLocalSelection(
    view: Pointer,
    anchorX: number,
    anchorY: number,
    focusX: number,
    focusY: number,
    bgColor: RGBA | null,
    fgColor: RGBA | null,
  ): boolean {
    return this.opentui.symbols.textBufferViewUpdateLocalSelection(
      view,
      anchorX,
      anchorY,
      focusX,
      focusY,
      bgColor?.buffer ?? null,
      fgColor?.buffer ?? null,
    )
  }

  public textBufferViewResetLocalSelection(view: Pointer): void {
    this.opentui.symbols.textBufferViewResetLocalSelection(view)
  }

  public textBufferViewSetWrapWidth(view: Pointer, width: number): void {
    this.opentui.symbols.textBufferViewSetWrapWidth(view, width)
  }

  public textBufferViewSetWrapMode(view: Pointer, mode: "none" | "char" | "word"): void {
    const modeValue = mode === "none" ? 0 : mode === "char" ? 1 : 2
    this.opentui.symbols.textBufferViewSetWrapMode(view, modeValue)
  }

  public textBufferViewSetViewportSize(view: Pointer, width: number, height: number): void {
    this.opentui.symbols.textBufferViewSetViewportSize(view, width, height)
  }

  public textBufferViewSetViewport(view: Pointer, x: number, y: number, width: number, height: number): void {
    this.opentui.symbols.textBufferViewSetViewport(view, x, y, width, height)
  }

  public textBufferViewGetLineInfo(view: Pointer): LineInfo {
    return this.opentui.symbols.textBufferViewGetLineInfo(view)
  }

  public textBufferViewGetLogicalLineInfo(view: Pointer): LineInfo {
    return this.opentui.symbols.textBufferViewGetLogicalLineInfo(view)
  }

  public textBufferViewGetSelectedTextBytes(view: Pointer, maxLength: number): Uint8Array | null {
    const raw = this.opentui.symbols.textBufferViewGetSelectedTextBytes(view, maxLength)
    return raw ? new Uint8Array(raw) : null
  }

  public textBufferViewGetPlainTextBytes(view: Pointer, maxLength: number): Uint8Array | null {
    const raw = this.opentui.symbols.textBufferViewGetPlainTextBytes(view, maxLength)
    return raw ? new Uint8Array(raw) : null
  }

  public textBufferViewSetTabIndicator(view: Pointer, indicator: number): void {
    this.opentui.symbols.textBufferViewSetTabIndicator(view, indicator)
  }

  public textBufferViewSetTabIndicatorColor(view: Pointer, color: RGBA): void {
    this.opentui.symbols.textBufferViewSetTabIndicatorColor(view, color.buffer)
  }

  public textBufferViewSetTruncate(view: Pointer, truncate: boolean): void {
    this.opentui.symbols.textBufferViewSetTruncate(view, truncate)
  }

  public textBufferViewMeasureForDimensions(
    view: Pointer,
    width: number,
    height: number,
  ): { lineCount: number; maxWidth: number } | null {
    return this.opentui.symbols.textBufferViewMeasureForDimensions(view, width, height)
  }

  public textBufferViewGetVirtualLineCount(view: Pointer): number {
    return this.opentui.symbols.textBufferViewGetVirtualLineCount(view)
  }

  public textBufferAddHighlightByCharRange(buffer: Pointer, highlight: Highlight): void {
    this.opentui.symbols.textBufferAddHighlightByCharRange(buffer, highlight)
  }

  public textBufferAddHighlight(buffer: Pointer, lineIdx: number, highlight: Highlight): void {
    this.opentui.symbols.textBufferAddHighlight(buffer, lineIdx, highlight)
  }

  public textBufferRemoveHighlightsByRef(buffer: Pointer, hlRef: number): void {
    this.opentui.symbols.textBufferRemoveHighlightsByRef(buffer, hlRef)
  }

  public textBufferClearLineHighlights(buffer: Pointer, lineIdx: number): void {
    this.opentui.symbols.textBufferClearLineHighlights(buffer, lineIdx)
  }

  public textBufferClearAllHighlights(buffer: Pointer): void {
    this.opentui.symbols.textBufferClearAllHighlights(buffer)
  }

  public textBufferSetSyntaxStyle(buffer: Pointer, style: Pointer | null): void {
    this.opentui.symbols.textBufferSetSyntaxStyle(buffer, style)
  }

  public textBufferGetLineHighlights(buffer: Pointer, lineIdx: number): Array<Highlight> {
    return this.opentui.symbols.textBufferGetLineHighlights(buffer, lineIdx)
  }

  public textBufferGetHighlightCount(buffer: Pointer): number {
    return this.opentui.symbols.textBufferGetHighlightCount(buffer)
  }

  public onNativeEvent(name: string, handler: (data: ArrayBuffer) => void): void {
    this._nativeEvents.on(name, handler)
  }

  public onceNativeEvent(name: string, handler: (data: ArrayBuffer) => void): void {
    this._nativeEvents.once(name, handler)
  }

  public offNativeEvent(name: string, handler: (data: ArrayBuffer) => void): void {
    this._nativeEvents.off(name, handler)
  }

  public onAnyNativeEvent(handler: (name: string, data: ArrayBuffer) => void): void {
    this._anyEventHandlers.push(handler)
  }
  createEditBuffer!: (widthMethod: WidthMethod) => Pointer
  destroyEditBuffer!: (buffer: Pointer) => void
  editBufferSetText!: (buffer: Pointer, textBytes: Uint8Array) => void
  editBufferSetTextFromMem!: (buffer: Pointer, memId: number) => void
  editBufferReplaceText!: (buffer: Pointer, textBytes: Uint8Array) => void
  editBufferReplaceTextFromMem!: (buffer: Pointer, memId: number) => void
  editBufferGetText!: (buffer: Pointer, maxLength: number) => Uint8Array | null
  editBufferInsertChar!: (buffer: Pointer, char: string) => void
  editBufferInsertText!: (buffer: Pointer, text: string) => void
  editBufferDeleteChar!: (buffer: Pointer) => void
  editBufferDeleteCharBackward!: (buffer: Pointer) => void
  editBufferDeleteRange!: (
    buffer: Pointer,
    startLine: number,
    startCol: number,
    endLine: number,
    endCol: number,
  ) => void
  editBufferNewLine!: (buffer: Pointer) => void
  editBufferDeleteLine!: (buffer: Pointer) => void
  editBufferMoveCursorLeft!: (buffer: Pointer) => void
  editBufferMoveCursorRight!: (buffer: Pointer) => void
  editBufferMoveCursorUp!: (buffer: Pointer) => void
  editBufferMoveCursorDown!: (buffer: Pointer) => void
  editBufferGotoLine!: (buffer: Pointer, line: number) => void
  editBufferSetCursor!: (buffer: Pointer, line: number, col: number) => void
  editBufferSetCursorToLineCol!: (buffer: Pointer, line: number, col: number) => void
  editBufferSetCursorByOffset!: (buffer: Pointer, offset: number) => void
  editBufferGetCursorPosition!: (buffer: Pointer) => LogicalCursor
  editBufferGetId!: (buffer: Pointer) => number
  editBufferGetTextBuffer!: (buffer: Pointer) => Pointer
  editBufferDebugLogRope!: (buffer: Pointer) => void
  editBufferUndo!: (buffer: Pointer, maxLength: number) => Uint8Array | null
  editBufferRedo!: (buffer: Pointer, maxLength: number) => Uint8Array | null
  editBufferCanUndo!: (buffer: Pointer) => boolean
  editBufferCanRedo!: (buffer: Pointer) => boolean
  editBufferClearHistory!: (buffer: Pointer) => void
  editBufferClear!: (buffer: Pointer) => void
  editBufferGetNextWordBoundary!: (buffer: Pointer) => { row: number; col: number; offset: number }
  editBufferGetPrevWordBoundary!: (buffer: Pointer) => { row: number; col: number; offset: number }
  editBufferGetEOL!: (buffer: Pointer) => { row: number; col: number; offset: number }
  editBufferOffsetToPosition!: (buffer: Pointer, offset: number) => { row: number; col: number; offset: number } | null
  editBufferPositionToOffset!: (buffer: Pointer, row: number, col: number) => number
  editBufferGetLineStartOffset!: (buffer: Pointer, row: number) => number
  editBufferGetTextRange!: (
    buffer: Pointer,
    startOffset: number,
    endOffset: number,
    maxLength: number,
  ) => Uint8Array | null
  editBufferGetTextRangeByCoords!: (
    buffer: Pointer,
    startRow: number,
    startCol: number,
    endRow: number,
    endCol: number,
    maxLength: number,
  ) => Uint8Array | null
  createEditorView!: (editBufferPtr: Pointer, viewportWidth: number, viewportHeight: number) => Pointer
  destroyEditorView!: (view: Pointer) => void
  editorViewSetViewportSize!: (view: Pointer, width: number, height: number) => void
  editorViewSetViewport!: (
    view: Pointer,
    x: number,
    y: number,
    width: number,
    height: number,
    moveCursor: boolean,
  ) => void
  editorViewGetViewport!: (view: Pointer) => { offsetY: number; offsetX: number; height: number; width: number }
  editorViewSetScrollMargin!: (view: Pointer, margin: number) => void
  editorViewSetWrapMode!: (view: Pointer, mode: "none" | "char" | "word") => void
  editorViewGetVirtualLineCount!: (view: Pointer) => number
  editorViewGetTotalVirtualLineCount!: (view: Pointer) => number
  editorViewGetTextBufferView!: (view: Pointer) => Pointer
  editorViewSetSelection!: (
    view: Pointer,
    start: number,
    end: number,
    bgColor: RGBA | null,
    fgColor: RGBA | null,
  ) => void
  editorViewResetSelection!: (view: Pointer) => void
  editorViewGetSelection!: (view: Pointer) => { start: number; end: number } | null
  editorViewSetLocalSelection!: (
    view: Pointer,
    anchorX: number,
    anchorY: number,
    focusX: number,
    focusY: number,
    bgColor: RGBA | null,
    fgColor: RGBA | null,
    updateCursor: boolean,
    followCursor: boolean,
  ) => boolean
  editorViewUpdateSelection!: (view: Pointer, end: number, bgColor: RGBA | null, fgColor: RGBA | null) => void
  editorViewUpdateLocalSelection!: (
    view: Pointer,
    anchorX: number,
    anchorY: number,
    focusX: number,
    focusY: number,
    bgColor: RGBA | null,
    fgColor: RGBA | null,
    updateCursor: boolean,
    followCursor: boolean,
  ) => boolean
  editorViewResetLocalSelection!: (view: Pointer) => void
  editorViewGetSelectedTextBytes!: (view: Pointer, maxLength: number) => Uint8Array | null
  editorViewGetCursor!: (view: Pointer) => { row: number; col: number }
  editorViewGetText!: (view: Pointer, maxLength: number) => Uint8Array | null
  editorViewGetVisualCursor!: (view: Pointer) => VisualCursor
  editorViewMoveUpVisual!: (view: Pointer) => void
  editorViewMoveDownVisual!: (view: Pointer) => void
  editorViewDeleteSelectedText!: (view: Pointer) => void
  editorViewSetCursorByOffset!: (view: Pointer, offset: number) => void
  editorViewGetNextWordBoundary!: (view: Pointer) => VisualCursor
  editorViewGetPrevWordBoundary!: (view: Pointer) => VisualCursor
  editorViewGetEOL!: (view: Pointer) => VisualCursor
  editorViewGetVisualSOL!: (view: Pointer) => VisualCursor
  editorViewGetVisualEOL!: (view: Pointer) => VisualCursor
  editorViewGetLineInfo!: (view: Pointer) => LineInfo
  editorViewGetLogicalLineInfo!: (view: Pointer) => LineInfo
  editorViewSetPlaceholderStyledText!: (
    view: Pointer,
    chunks: Array<{ text: string; fg?: RGBA | null; bg?: RGBA | null; attributes?: number }>,
  ) => void
  editorViewSetTabIndicator!: (view: Pointer, indicator: number) => void
  editorViewSetTabIndicatorColor!: (view: Pointer, color: RGBA) => void
  getArenaAllocatedBytes!: () => number
  createSyntaxStyle!: () => Pointer
  destroySyntaxStyle!: (style: Pointer) => void
  syntaxStyleRegister!: (style: Pointer, name: string, fg: RGBA | null, bg: RGBA | null, attributes: number) => number
  syntaxStyleResolveByName!: (style: Pointer, name: string) => number | null
  syntaxStyleGetStyleCount!: (style: Pointer) => number
  getTerminalCapabilities!: (renderer: Pointer) => any
  processCapabilityResponse!: (renderer: Pointer, response: string) => void
  encodeUnicode!: (
    text: string,
    widthMethod: WidthMethod,
  ) => { ptr: Pointer; data: Array<{ width: number; char: number }> } | null
  freeUnicode!: (encoded: { ptr: Pointer; data: Array<{ width: number; char: number }> }) => void
}
