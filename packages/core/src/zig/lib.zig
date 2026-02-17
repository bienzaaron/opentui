const std = @import("std");
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const buffer = @import("buffer.zig");
const renderer = @import("renderer.zig");
const gp = @import("grapheme.zig");
const link = @import("link.zig");
const text_buffer = @import("text-buffer.zig");
const text_buffer_view = @import("text-buffer-view.zig");
const edit_buffer_mod = @import("edit-buffer.zig");
const editor_view = @import("editor-view.zig");
const syntax_style = @import("syntax-style.zig");
const terminal = @import("terminal.zig");
const utf8 = @import("utf8.zig");
const logger = @import("logger.zig");
const event_bus = @import("event-bus.zig");
const utils = @import("utils.zig");

pub const OptimizedBuffer = buffer.OptimizedBuffer;
pub const CliRenderer = renderer.CliRenderer;
pub const Terminal = terminal.Terminal;
pub const RGBA = buffer.RGBA;
pub const TextBuffer = text_buffer.TextBuffer;
pub const TextBufferView = text_buffer_view.TextBufferView;
pub const EditBuffer = edit_buffer_mod.EditBuffer;
pub const EditorView = editor_view.EditorView;
pub const StyledChunk = text_buffer.StyledChunk;
pub const SyntaxStyle = syntax_style.SyntaxStyle;

pub export fn setLogCallback(callback: ?*const fn (level: u8, msgPtr: [*]const u8, msgLen: usize) callconv(.c) void) void {
    logger.setLogCallback(callback);
}

pub export fn setEventCallback(callback: ?*const fn (namePtr: [*]const u8, nameLen: usize, dataPtr: [*]const u8, dataLen: usize) callconv(.c) void) void {
    event_bus.setEventCallback(callback);
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const globalAllocator = gpa.allocator();
var arena = std.heap.ArenaAllocator.init(globalAllocator);
const globalArena = arena.allocator();

pub export fn getArenaAllocatedBytes() usize {
    return arena.queryCapacity();
}

pub export fn createRenderer(width: u32, height: u32, testing: bool, remote: bool) ?*renderer.CliRenderer {
    if (width == 0 or height == 0) {
        logger.warn("Invalid renderer dimensions: {}x{}", .{ width, height });
        return null;
    }

    const pool = gp.initGlobalPool(globalArena);
    _ = link.initGlobalLinkPool(globalArena);
    return renderer.CliRenderer.createWithOptions(globalAllocator, width, height, pool, testing, remote) catch |err| {
        logger.err("Failed to create renderer: {}", .{err});
        return null;
    };
}

pub export fn setUseThread(rendererPtr: *renderer.CliRenderer, useThread: bool) void {
    rendererPtr.setUseThread(useThread);
}

pub export fn destroyRenderer(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.destroy();
}

pub export fn setBackgroundColor(rendererPtr: *renderer.CliRenderer, color: [*]const f32) void {
    rendererPtr.setBackgroundColor(utils.f32PtrToRGBA(color));
}

pub export fn setRenderOffset(rendererPtr: *renderer.CliRenderer, offset: u32) void {
    rendererPtr.setRenderOffset(offset);
}

pub export fn updateStats(rendererPtr: *renderer.CliRenderer, time: f64, fps: u32, frameCallbackTime: f64) void {
    rendererPtr.updateStats(time, fps, frameCallbackTime);
}

pub export fn updateMemoryStats(rendererPtr: *renderer.CliRenderer, heapUsed: u32, heapTotal: u32, arrayBuffers: u32) void {
    rendererPtr.updateMemoryStats(heapUsed, heapTotal, arrayBuffers);
}

pub export fn getNextBuffer(rendererPtr: *renderer.CliRenderer) *buffer.OptimizedBuffer {
    return rendererPtr.getNextBuffer();
}

pub export fn getCurrentBuffer(rendererPtr: *renderer.CliRenderer) *buffer.OptimizedBuffer {
    return rendererPtr.getCurrentBuffer();
}

const OutputSlice = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub export fn getLastOutputForTest(rendererPtr: *renderer.CliRenderer, outSlice: *OutputSlice) void {
    const output = rendererPtr.getLastOutputForTest();
    outSlice.ptr = output.ptr;
    outSlice.len = output.len;
}

pub export fn setHyperlinksCapability(rendererPtr: *renderer.CliRenderer, enabled: bool) void {
    rendererPtr.terminal.caps.hyperlinks = enabled;
}

pub export fn clearGlobalLinkPool() void {
    link.deinitGlobalLinkPool();
}

pub export fn getBufferWidth(bufferPtr: *buffer.OptimizedBuffer) u32 {
    return bufferPtr.width;
}

pub export fn getBufferHeight(bufferPtr: *buffer.OptimizedBuffer) u32 {
    return bufferPtr.height;
}

pub export fn render(rendererPtr: *renderer.CliRenderer, force: bool) void {
    rendererPtr.render(force);
}

pub export fn createOptimizedBuffer(width: u32, height: u32, respectAlpha: bool, widthMethod: u8, idPtr: [*]const u8, idLen: usize) ?*buffer.OptimizedBuffer {
    if (width == 0 or height == 0) {
        logger.warn("Invalid buffer dimensions: {}x{}", .{ width, height });
        return null;
    }

    const pool = gp.initGlobalPool(globalArena);
    const link_pool = link.initGlobalLinkPool(globalArena);
    const wMethod: utf8.WidthMethod = if (widthMethod == 0) .wcwidth else .unicode;
    const id = idPtr[0..idLen];

    return buffer.OptimizedBuffer.init(globalAllocator, width, height, .{
        .respectAlpha = respectAlpha,
        .pool = pool,
        .width_method = wMethod,
        .id = id,
        .link_pool = link_pool,
    }) catch |err| {
        logger.err("Failed to create optimized buffer: {}", .{err});
        return null;
    };
}

pub export fn destroyOptimizedBuffer(bufferPtr: *buffer.OptimizedBuffer) void {
    bufferPtr.deinit();
}

pub export fn destroyFrameBuffer(frameBufferPtr: *buffer.OptimizedBuffer) void {
    destroyOptimizedBuffer(frameBufferPtr);
}

pub export fn drawFrameBuffer(targetPtr: *buffer.OptimizedBuffer, destX: i32, destY: i32, frameBuffer: *buffer.OptimizedBuffer, sourceX: u32, sourceY: u32, sourceWidth: u32, sourceHeight: u32) void {
    const srcX = if (sourceX == 0) null else sourceX;
    const srcY = if (sourceY == 0) null else sourceY;
    const srcWidth = if (sourceWidth == 0) null else sourceWidth;
    const srcHeight = if (sourceHeight == 0) null else sourceHeight;

    targetPtr.drawFrameBuffer(destX, destY, frameBuffer, srcX, srcY, srcWidth, srcHeight);
}

pub export fn setCursorPosition(rendererPtr: *renderer.CliRenderer, x: i32, y: i32, visible: bool) void {
    rendererPtr.terminal.setCursorPosition(@intCast(@max(1, x)), @intCast(@max(1, y)), visible);
}

pub const ExternalCapabilities = extern struct {
    kitty_keyboard: bool,
    kitty_graphics: bool,
    rgb: bool,
    unicode: u8, // 0 = wcwidth, 1 = unicode
    sgr_pixels: bool,
    color_scheme_updates: bool,
    explicit_width: bool,
    scaled_text: bool,
    sixel: bool,
    focus_tracking: bool,
    sync: bool,
    bracketed_paste: bool,
    hyperlinks: bool,
    osc52: bool,
    explicit_cursor_positioning: bool,
    term_name_ptr: [*]const u8,
    term_name_len: usize,
    term_version_ptr: [*]const u8,
    term_version_len: usize,
    term_from_xtversion: bool,
};

pub export fn getTerminalCapabilities(rendererPtr: *renderer.CliRenderer, capsPtr: *ExternalCapabilities) void {
    const caps = rendererPtr.getTerminalCapabilities();
    const term = &rendererPtr.terminal;

    capsPtr.* = .{
        .kitty_keyboard = caps.kitty_keyboard,
        .kitty_graphics = caps.kitty_graphics,
        .rgb = caps.rgb,
        .unicode = if (caps.unicode == .wcwidth) 0 else 1,
        .sgr_pixels = caps.sgr_pixels,
        .color_scheme_updates = caps.color_scheme_updates,
        .explicit_width = caps.explicit_width,
        .scaled_text = caps.scaled_text,
        .sixel = caps.sixel,
        .focus_tracking = caps.focus_tracking,
        .sync = caps.sync,
        .bracketed_paste = caps.bracketed_paste,
        .hyperlinks = caps.hyperlinks,
        .osc52 = caps.osc52,
        .explicit_cursor_positioning = caps.explicit_cursor_positioning,
        .term_name_ptr = &term.term_info.name,
        .term_name_len = term.term_info.name_len,
        .term_version_ptr = &term.term_info.version,
        .term_version_len = term.term_info.version_len,
        .term_from_xtversion = term.term_info.from_xtversion,
    };
}

pub export fn processCapabilityResponse(rendererPtr: *renderer.CliRenderer, responsePtr: [*]const u8, responseLen: usize) void {
    const response = responsePtr[0..responseLen];
    rendererPtr.processCapabilityResponse(response);
}

pub export fn setCursorStyle(rendererPtr: *renderer.CliRenderer, stylePtr: [*]const u8, styleLen: usize, blinking: bool) void {
    const style = stylePtr[0..styleLen];
    const cursorStyle = std.meta.stringToEnum(terminal.CursorStyle, style) orelse .block;
    rendererPtr.terminal.setCursorStyle(cursorStyle, blinking);
}

pub export fn setCursorColor(rendererPtr: *renderer.CliRenderer, color: [*]const f32) void {
    rendererPtr.terminal.setCursorColor(utils.f32PtrToRGBA(color));
}

pub const ExternalCursorState = extern struct {
    x: u32,
    y: u32,
    visible: bool,
    style: u8,
    blinking: bool,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub export fn getCursorState(rendererPtr: *renderer.CliRenderer, outPtr: *ExternalCursorState) void {
    const pos = rendererPtr.terminal.getCursorPosition();
    const style = rendererPtr.terminal.getCursorStyle();
    const color = rendererPtr.terminal.getCursorColor();

    const styleTag: u8 = switch (style.style) {
        .block => 0,
        .line => 1,
        .underline => 2,
    };

    outPtr.* = .{
        .x = pos.x,
        .y = pos.y,
        .visible = pos.visible,
        .style = styleTag,
        .blinking = style.blinking,
        .r = color[0],
        .g = color[1],
        .b = color[2],
        .a = color[3],
    };
}

pub export fn setDebugOverlay(rendererPtr: *renderer.CliRenderer, enabled: bool, corner: u8) void {
    const cornerEnum: renderer.DebugOverlayCorner = switch (corner) {
        0 => .topLeft,
        1 => .topRight,
        2 => .bottomLeft,
        else => .bottomRight,
    };

    rendererPtr.setDebugOverlay(enabled, cornerEnum);
}

pub export fn clearTerminal(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.clearTerminal();
}

pub export fn setTerminalTitle(rendererPtr: *renderer.CliRenderer, titlePtr: [*]const u8, titleLen: usize) void {
    const title = titlePtr[0..titleLen];
    rendererPtr.setTerminalTitle(title);
}

pub export fn copyToClipboardOSC52(rendererPtr: *renderer.CliRenderer, target: u8, payloadPtr: [*]const u8, payloadLen: usize) bool {
    const targetEnum = std.meta.intToEnum(terminal.ClipboardTarget, target) catch .clipboard;
    const payload = payloadPtr[0..payloadLen];
    return rendererPtr.copyToClipboardOSC52(targetEnum, payload);
}

pub export fn clearClipboardOSC52(rendererPtr: *renderer.CliRenderer, target: u8) bool {
    const targetEnum = std.meta.intToEnum(terminal.ClipboardTarget, target) catch .clipboard;
    return rendererPtr.clearClipboardOSC52(targetEnum);
}

// Buffer functions
pub export fn bufferClear(bufferPtr: *buffer.OptimizedBuffer, bg: [*]const f32) void {
    bufferPtr.clear(utils.f32PtrToRGBA(bg), null) catch {};
}

pub export fn bufferGetCharPtr(bufferPtr: *buffer.OptimizedBuffer) [*]u32 {
    return bufferPtr.getCharPtr();
}

pub export fn bufferGetFgPtr(bufferPtr: *buffer.OptimizedBuffer) [*]RGBA {
    return bufferPtr.getFgPtr();
}

pub export fn bufferGetBgPtr(bufferPtr: *buffer.OptimizedBuffer) [*]RGBA {
    return bufferPtr.getBgPtr();
}

pub export fn bufferGetAttributesPtr(bufferPtr: *buffer.OptimizedBuffer) [*]u32 {
    return bufferPtr.getAttributesPtr();
}

pub export fn bufferGetRespectAlpha(bufferPtr: *buffer.OptimizedBuffer) bool {
    return bufferPtr.getRespectAlpha();
}

pub export fn bufferSetRespectAlpha(bufferPtr: *buffer.OptimizedBuffer, respectAlpha: bool) void {
    bufferPtr.setRespectAlpha(respectAlpha);
}

pub export fn bufferGetId(bufferPtr: *buffer.OptimizedBuffer, outPtr: [*]u8, maxLen: usize) usize {
    const id = bufferPtr.getId();
    const copyLen = @min(id.len, maxLen);
    @memcpy(outPtr[0..copyLen], id[0..copyLen]);
    return copyLen;
}

pub export fn bufferGetRealCharSize(bufferPtr: *buffer.OptimizedBuffer) u32 {
    return bufferPtr.getRealCharSize();
}

pub export fn bufferWriteResolvedChars(bufferPtr: *buffer.OptimizedBuffer, outputPtr: [*]u8, outputLen: usize, addLineBreaks: bool) u32 {
    const output_slice = outputPtr[0..outputLen];
    return bufferPtr.writeResolvedChars(output_slice, addLineBreaks) catch 0;
}

pub export fn bufferDrawText(bufferPtr: *buffer.OptimizedBuffer, text: [*]const u8, textLen: usize, x: u32, y: u32, fg: [*]const f32, bg: ?[*]const f32, attributes: u32) void {
    const rgbaFg = utils.f32PtrToRGBA(fg);
    const rgbaBg = if (bg) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    bufferPtr.drawText(text[0..textLen], x, y, rgbaFg, rgbaBg, attributes) catch {};
}

pub export fn bufferSetCellWithAlphaBlending(bufferPtr: *buffer.OptimizedBuffer, x: u32, y: u32, char: u32, fg: [*]const f32, bg: [*]const f32, attributes: u32) void {
    const rgbaFg = utils.f32PtrToRGBA(fg);
    const rgbaBg = utils.f32PtrToRGBA(bg);
    bufferPtr.setCellWithAlphaBlending(x, y, char, rgbaFg, rgbaBg, attributes) catch {};
}

pub export fn bufferSetCell(bufferPtr: *buffer.OptimizedBuffer, x: u32, y: u32, char: u32, fg: [*]const f32, bg: [*]const f32, attributes: u32) void {
    const rgbaFg = utils.f32PtrToRGBA(fg);
    const rgbaBg = utils.f32PtrToRGBA(bg);
    const cell = buffer.Cell{
        .char = char,
        .fg = rgbaFg,
        .bg = rgbaBg,
        .attributes = attributes,
    };
    bufferPtr.set(x, y, cell);
}

pub export fn bufferFillRect(bufferPtr: *buffer.OptimizedBuffer, x: u32, y: u32, width: u32, height: u32, bg: [*]const f32) void {
    const rgbaBg = utils.f32PtrToRGBA(bg);
    bufferPtr.fillRect(x, y, width, height, rgbaBg) catch {};
}

pub export fn bufferDrawPackedBuffer(bufferPtr: *buffer.OptimizedBuffer, data: [*]const u8, dataLen: usize, posX: u32, posY: u32, terminalWidthCells: u32, terminalHeightCells: u32) void {
    bufferPtr.drawPackedBuffer(data, dataLen, posX, posY, terminalWidthCells, terminalHeightCells);
}

pub export fn bufferDrawGrayscaleBuffer(bufferPtr: *buffer.OptimizedBuffer, posX: i32, posY: i32, intensities: [*]const f32, srcWidth: u32, srcHeight: u32, fg: ?[*]const f32, bg: ?[*]const f32) void {
    const rgbaFg = if (fg) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    const rgbaBg = if (bg) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    bufferPtr.drawGrayscaleBuffer(posX, posY, intensities, srcWidth, srcHeight, rgbaFg, rgbaBg);
}

pub export fn bufferDrawGrayscaleBufferSupersampled(bufferPtr: *buffer.OptimizedBuffer, posX: i32, posY: i32, intensities: [*]const f32, srcWidth: u32, srcHeight: u32, fg: ?[*]const f32, bg: ?[*]const f32) void {
    const rgbaFg = if (fg) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    const rgbaBg = if (bg) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    bufferPtr.drawGrayscaleBufferSupersampled(posX, posY, intensities, srcWidth, srcHeight, rgbaFg, rgbaBg);
}

pub export fn bufferPushScissorRect(bufferPtr: *buffer.OptimizedBuffer, x: i32, y: i32, width: u32, height: u32) void {
    bufferPtr.pushScissorRect(x, y, width, height) catch {};
}

pub export fn bufferPopScissorRect(bufferPtr: *buffer.OptimizedBuffer) void {
    bufferPtr.popScissorRect();
}

pub export fn bufferClearScissorRects(bufferPtr: *buffer.OptimizedBuffer) void {
    bufferPtr.clearScissorRects();
}

// Opacity stack functions
pub export fn bufferPushOpacity(bufferPtr: *buffer.OptimizedBuffer, opacity: f32) void {
    bufferPtr.pushOpacity(opacity) catch {};
}

pub export fn bufferPopOpacity(bufferPtr: *buffer.OptimizedBuffer) void {
    bufferPtr.popOpacity();
}

pub export fn bufferGetCurrentOpacity(bufferPtr: *buffer.OptimizedBuffer) f32 {
    return bufferPtr.getCurrentOpacity();
}

pub export fn bufferClearOpacity(bufferPtr: *buffer.OptimizedBuffer) void {
    bufferPtr.clearOpacity();
}

pub export fn bufferDrawSuperSampleBuffer(bufferPtr: *buffer.OptimizedBuffer, x: u32, y: u32, pixelData: [*]const u8, len: usize, format: u8, alignedBytesPerRow: u32) void {
    bufferPtr.drawSuperSampleBuffer(x, y, pixelData, len, format, alignedBytesPerRow) catch {};
}

pub export fn linkAlloc(urlPtr: [*]const u8, urlLen: usize) u32 {
    const url = urlPtr[0..urlLen];
    const link_pool = link.initGlobalLinkPool(globalArena);
    return link_pool.alloc(url) catch 0;
}

pub export fn linkGetUrl(id: u32, outPtr: [*]u8, maxLen: usize) usize {
    const link_pool = link.initGlobalLinkPool(globalArena);
    const url_bytes = link_pool.get(id) catch return 0;
    const copyLen = @min(url_bytes.len, maxLen);
    @memcpy(outPtr[0..copyLen], url_bytes[0..copyLen]);
    return copyLen;
}

pub export fn attributesWithLink(baseAttributes: u32, linkId: u32) u32 {
    return ansi.TextAttributes.setLinkId(baseAttributes, linkId);
}

pub export fn attributesGetLinkId(attributes: u32) u32 {
    return ansi.TextAttributes.getLinkId(attributes);
}

pub export fn bufferDrawBox(
    bufferPtr: *buffer.OptimizedBuffer,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    borderChars: [*]const u32,
    packedOptions: u32,
    borderColor: [*]const f32,
    backgroundColor: [*]const f32,
    title: ?[*]const u8,
    titleLen: u32,
) void {
    const borderSides = buffer.BorderSides{
        .top = (packedOptions & 0b1000) != 0,
        .right = (packedOptions & 0b0100) != 0,
        .bottom = (packedOptions & 0b0010) != 0,
        .left = (packedOptions & 0b0001) != 0,
    };

    const shouldFill = ((packedOptions >> 4) & 1) != 0;
    const titleAlignment = @as(u8, @intCast((packedOptions >> 5) & 0b11));

    const titleSlice = if (title) |t| t[0..titleLen] else null;

    bufferPtr.drawBox(
        x,
        y,
        width,
        height,
        borderChars,
        borderSides,
        utils.f32PtrToRGBA(borderColor),
        utils.f32PtrToRGBA(backgroundColor),
        shouldFill,
        titleSlice,
        titleAlignment,
    ) catch {};
}

pub export fn bufferResize(bufferPtr: *buffer.OptimizedBuffer, width: u32, height: u32) void {
    bufferPtr.resize(width, height) catch {};
}

pub export fn resizeRenderer(rendererPtr: *renderer.CliRenderer, width: u32, height: u32) void {
    rendererPtr.resize(width, height) catch {};
}

pub export fn addToHitGrid(rendererPtr: *renderer.CliRenderer, x: i32, y: i32, width: u32, height: u32, id: u32) void {
    rendererPtr.addToHitGrid(x, y, width, height, id);
}

pub export fn clearCurrentHitGrid(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.clearCurrentHitGrid();
}

pub export fn hitGridPushScissorRect(rendererPtr: *renderer.CliRenderer, x: i32, y: i32, width: u32, height: u32) void {
    rendererPtr.hitGridPushScissorRect(x, y, width, height);
}

pub export fn hitGridPopScissorRect(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.hitGridPopScissorRect();
}

pub export fn hitGridClearScissorRects(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.hitGridClearScissorRects();
}

pub export fn addToCurrentHitGridClipped(rendererPtr: *renderer.CliRenderer, x: i32, y: i32, width: u32, height: u32, id: u32) void {
    rendererPtr.addToCurrentHitGridClipped(x, y, width, height, id);
}

pub export fn checkHit(rendererPtr: *renderer.CliRenderer, x: u32, y: u32) u32 {
    return rendererPtr.checkHit(x, y);
}

pub export fn getHitGridDirty(rendererPtr: *renderer.CliRenderer) bool {
    return rendererPtr.getHitGridDirty();
}

pub export fn dumpHitGrid(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.dumpHitGrid();
}

pub export fn dumpBuffers(rendererPtr: *renderer.CliRenderer, timestamp: i64) void {
    rendererPtr.dumpBuffers(timestamp);
}

pub export fn dumpStdoutBuffer(rendererPtr: *renderer.CliRenderer, timestamp: i64) void {
    rendererPtr.dumpStdoutBuffer(timestamp);
}

pub export fn enableMouse(rendererPtr: *renderer.CliRenderer, enableMovement: bool) void {
    rendererPtr.enableMouse(enableMovement);
}

pub export fn disableMouse(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.disableMouse();
}

pub export fn queryPixelResolution(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.queryPixelResolution();
}

pub export fn enableKittyKeyboard(rendererPtr: *renderer.CliRenderer, flags: u8) void {
    rendererPtr.enableKittyKeyboard(flags);
}

pub export fn disableKittyKeyboard(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.disableKittyKeyboard();
}

pub export fn setKittyKeyboardFlags(rendererPtr: *renderer.CliRenderer, flags: u8) void {
    rendererPtr.setKittyKeyboardFlags(flags);
}

pub export fn getKittyKeyboardFlags(rendererPtr: *renderer.CliRenderer) u8 {
    return rendererPtr.getKittyKeyboardFlags();
}

pub export fn setupTerminal(rendererPtr: *renderer.CliRenderer, useAlternateScreen: bool) void {
    rendererPtr.setupTerminal(useAlternateScreen);
}

pub export fn suspendRenderer(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.suspendRenderer();
}

pub export fn resumeRenderer(rendererPtr: *renderer.CliRenderer) void {
    rendererPtr.resumeRenderer();
}

pub export fn writeOut(rendererPtr: *renderer.CliRenderer, dataPtr: [*]const u8, dataLen: usize) void {
    if (dataLen == 0) return;
    const data = dataPtr[0..dataLen];
    rendererPtr.writeOut(data);
}

pub export fn createTextBuffer(widthMethod: u8) ?*text_buffer.UnifiedTextBuffer {
    const pool = gp.initGlobalPool(globalArena);
    const wMethod: utf8.WidthMethod = if (widthMethod == 0) .wcwidth else .unicode;

    const tb = text_buffer.UnifiedTextBuffer.init(globalAllocator, pool, wMethod) catch {
        return null;
    };

    return tb;
}

pub export fn destroyTextBuffer(tb: *text_buffer.UnifiedTextBuffer) void {
    tb.deinit();
}

pub export fn textBufferGetLength(tb: *text_buffer.UnifiedTextBuffer) u32 {
    return tb.getLength();
}

pub export fn textBufferGetByteSize(tb: *text_buffer.UnifiedTextBuffer) u32 {
    return tb.getByteSize();
}

pub export fn textBufferReset(tb: *text_buffer.UnifiedTextBuffer) void {
    tb.reset();
}

pub export fn textBufferClear(tb: *text_buffer.UnifiedTextBuffer) void {
    tb.clear();
}

pub export fn textBufferSetDefaultFg(tb: *text_buffer.UnifiedTextBuffer, fg: ?[*]const f32) void {
    const fgColor = if (fg) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    tb.setDefaultFg(fgColor);
}

pub export fn textBufferSetDefaultBg(tb: *text_buffer.UnifiedTextBuffer, bg: ?[*]const f32) void {
    const bgColor = if (bg) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    tb.setDefaultBg(bgColor);
}

pub export fn textBufferSetDefaultAttributes(tb: *text_buffer.UnifiedTextBuffer, attr: ?[*]const u32) void {
    const attributes = if (attr) |a| a[0] else null;
    tb.setDefaultAttributes(attributes);
}

pub export fn textBufferResetDefaults(tb: *text_buffer.UnifiedTextBuffer) void {
    tb.resetDefaults();
}

pub export fn textBufferGetTabWidth(tb: *text_buffer.UnifiedTextBuffer) u8 {
    return tb.getTabWidth();
}

pub export fn textBufferSetTabWidth(tb: *text_buffer.UnifiedTextBuffer, width: u8) void {
    tb.setTabWidth(width);
}

pub export fn textBufferRegisterMemBuffer(tb: *text_buffer.UnifiedTextBuffer, dataPtr: [*]const u8, dataLen: usize, owned: bool) u16 {
    const data = dataPtr[0..dataLen];
    const mem_id = tb.mem_registry.register(data, owned) catch return 0xFFFF;
    return @intCast(mem_id);
}

pub export fn textBufferReplaceMemBuffer(tb: *text_buffer.UnifiedTextBuffer, id: u8, dataPtr: [*]const u8, dataLen: usize, owned: bool) bool {
    const data = dataPtr[0..dataLen];
    tb.mem_registry.replace(id, data, owned) catch return false;
    return true;
}

pub export fn textBufferClearMemRegistry(tb: *text_buffer.UnifiedTextBuffer) void {
    tb.mem_registry.clear();
}

pub export fn textBufferSetTextFromMem(tb: *text_buffer.UnifiedTextBuffer, id: u8) void {
    tb.setTextFromMemId(id) catch {};
}

pub export fn textBufferAppend(tb: *text_buffer.UnifiedTextBuffer, dataPtr: [*]const u8, dataLen: usize) void {
    const data = dataPtr[0..dataLen];
    tb.append(data) catch {};
}

pub export fn textBufferAppendFromMemId(tb: *text_buffer.UnifiedTextBuffer, id: u8) void {
    tb.appendFromMemId(id) catch {};
}

pub export fn textBufferLoadFile(tb: *text_buffer.UnifiedTextBuffer, pathPtr: [*]const u8, pathLen: usize) bool {
    const path = pathPtr[0..pathLen];
    tb.loadFile(path) catch return false;
    return true;
}

pub export fn textBufferSetStyledText(
    tb: *text_buffer.UnifiedTextBuffer,
    chunksPtr: [*]const text_buffer.StyledChunk,
    chunkCount: usize,
) void {
    if (chunkCount == 0) return;
    const chunks = chunksPtr[0..chunkCount];
    tb.setStyledText(chunks) catch {};
}

pub export fn textBufferGetLineCount(tb: *text_buffer.UnifiedTextBuffer) u32 {
    return tb.getLineCount();
}

pub export fn textBufferGetPlainText(tb: *text_buffer.UnifiedTextBuffer, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return tb.getPlainTextIntoBuffer(outBuffer);
}

// TextBufferView functions (Array-based for backward compatibility)
pub export fn createTextBufferView(tb: *text_buffer.UnifiedTextBuffer) ?*text_buffer_view.UnifiedTextBufferView {
    const view = text_buffer_view.UnifiedTextBufferView.init(globalAllocator, tb) catch {
        return null;
    };
    return view;
}

pub export fn destroyTextBufferView(view: *text_buffer_view.UnifiedTextBufferView) void {
    view.deinit();
}

pub export fn textBufferViewSetSelection(view: *text_buffer_view.UnifiedTextBufferView, start: u32, end: u32, bgColor: ?[*]const f32, fgColor: ?[*]const f32) void {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    view.setSelection(start, end, bg, fg);
}

pub export fn textBufferViewResetSelection(view: *text_buffer_view.UnifiedTextBufferView) void {
    view.resetSelection();
}

pub export fn textBufferViewGetSelectionInfo(view: *text_buffer_view.UnifiedTextBufferView) u64 {
    return view.packSelectionInfo();
}

pub export fn textBufferViewSetLocalSelection(view: *text_buffer_view.UnifiedTextBufferView, anchorX: i32, anchorY: i32, focusX: i32, focusY: i32, bgColor: ?[*]const f32, fgColor: ?[*]const f32) bool {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    return view.setLocalSelection(anchorX, anchorY, focusX, focusY, bg, fg);
}

pub export fn textBufferViewUpdateSelection(view: *text_buffer_view.UnifiedTextBufferView, end: u32, bgColor: ?[*]const f32, fgColor: ?[*]const f32) void {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    view.updateSelection(end, bg, fg);
}

pub export fn textBufferViewUpdateLocalSelection(view: *text_buffer_view.UnifiedTextBufferView, anchorX: i32, anchorY: i32, focusX: i32, focusY: i32, bgColor: ?[*]const f32, fgColor: ?[*]const f32) bool {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    return view.updateLocalSelection(anchorX, anchorY, focusX, focusY, bg, fg);
}

pub export fn textBufferViewResetLocalSelection(view: *text_buffer_view.UnifiedTextBufferView) void {
    view.resetLocalSelection();
}

pub export fn textBufferViewSetWrapWidth(view: *text_buffer_view.UnifiedTextBufferView, width: u32) void {
    view.setWrapWidth(if (width == 0) null else width);
}

pub export fn textBufferViewSetWrapMode(view: *text_buffer_view.UnifiedTextBufferView, mode: u8) void {
    const wrapMode: text_buffer.WrapMode = switch (mode) {
        0 => .none,
        1 => .char,
        2 => .word,
        else => .none,
    };
    view.setWrapMode(wrapMode);
}

pub export fn textBufferViewSetViewportSize(view: *text_buffer_view.UnifiedTextBufferView, width: u32, height: u32) void {
    view.setViewportSize(width, height);
}

pub export fn textBufferViewSetViewport(view: *text_buffer_view.UnifiedTextBufferView, x: u32, y: u32, width: u32, height: u32) void {
    view.setViewport(text_buffer_view.Viewport{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    });
}

pub export fn textBufferViewGetVirtualLineCount(view: *text_buffer_view.UnifiedTextBufferView) u32 {
    return view.getVirtualLineCount();
}

pub export fn textBufferViewGetLineInfoDirect(view: *text_buffer_view.UnifiedTextBufferView, outPtr: *ExternalLineInfo) void {
    const line_info = view.getCachedLineInfo();

    outPtr.* = .{
        .starts_ptr = line_info.starts.ptr,
        .starts_len = @intCast(line_info.starts.len),
        .widths_ptr = line_info.widths.ptr,
        .widths_len = @intCast(line_info.widths.len),
        .sources_ptr = line_info.sources.ptr,
        .sources_len = @intCast(line_info.sources.len),
        .wraps_ptr = line_info.wraps.ptr,
        .wraps_len = @intCast(line_info.wraps.len),
        .max_width = line_info.max_width,
    };
}

pub export fn textBufferViewGetLogicalLineInfoDirect(view: *text_buffer_view.UnifiedTextBufferView, outPtr: *ExternalLineInfo) void {
    const line_info = view.getLogicalLineInfo();

    outPtr.* = .{
        .starts_ptr = line_info.starts.ptr,
        .starts_len = @intCast(line_info.starts.len),
        .widths_ptr = line_info.widths.ptr,
        .widths_len = @intCast(line_info.widths.len),
        .sources_ptr = line_info.sources.ptr,
        .sources_len = @intCast(line_info.sources.len),
        .wraps_ptr = line_info.wraps.ptr,
        .wraps_len = @intCast(line_info.wraps.len),
        .max_width = line_info.max_width,
    };
}

pub export fn textBufferViewGetSelectedText(view: *text_buffer_view.UnifiedTextBufferView, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return view.getSelectedTextIntoBuffer(outBuffer);
}

pub export fn textBufferViewGetPlainText(view: *text_buffer_view.UnifiedTextBufferView, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return view.getPlainTextIntoBuffer(outBuffer);
}

pub export fn textBufferViewSetTabIndicator(view: *text_buffer_view.UnifiedTextBufferView, indicator: u32) void {
    view.setTabIndicator(indicator);
}

pub export fn textBufferViewSetTabIndicatorColor(view: *text_buffer_view.UnifiedTextBufferView, color: [*]const f32) void {
    view.setTabIndicatorColor(utils.f32PtrToRGBA(color));
}

pub export fn textBufferViewSetTruncate(view: *text_buffer_view.UnifiedTextBufferView, truncate: bool) void {
    view.setTruncate(truncate);
}

pub const ExternalMeasureResult = extern struct {
    line_count: u32,
    max_width: u32,
};

pub export fn textBufferViewMeasureForDimensions(view: *text_buffer_view.UnifiedTextBufferView, width: u32, height: u32, outPtr: *ExternalMeasureResult) bool {
    const result = view.measureForDimensions(width, height) catch return false;
    outPtr.* = .{
        .line_count = result.line_count,
        .max_width = result.max_width,
    };
    return true;
}

// ===== EditBuffer Exports =====

pub export fn createEditBuffer(widthMethod: u8) ?*edit_buffer_mod.EditBuffer {
    const pool = gp.initGlobalPool(globalArena);
    const wMethod: utf8.WidthMethod = if (widthMethod == 0) .wcwidth else .unicode;

    return edit_buffer_mod.EditBuffer.init(
        globalAllocator,
        pool,
        wMethod,
    ) catch null;
}

pub export fn destroyEditBuffer(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.deinit();
}

pub export fn editBufferGetTextBuffer(edit_buffer: *edit_buffer_mod.EditBuffer) *text_buffer.UnifiedTextBuffer {
    return edit_buffer.getTextBuffer();
}

pub export fn editBufferInsertText(edit_buffer: *edit_buffer_mod.EditBuffer, textPtr: [*]const u8, textLen: usize) void {
    const text = textPtr[0..textLen];
    edit_buffer.insertText(text) catch {};
}

pub export fn editBufferDeleteRange(edit_buffer: *edit_buffer_mod.EditBuffer, start_row: u32, start_col: u32, end_row: u32, end_col: u32) void {
    const start = edit_buffer_mod.Cursor{ .row = start_row, .col = start_col };
    const end = edit_buffer_mod.Cursor{ .row = end_row, .col = end_col };
    edit_buffer.deleteRange(start, end) catch {};
}

pub export fn editBufferDeleteCharBackward(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.backspace() catch {};
}

pub export fn editBufferDeleteChar(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.deleteForward() catch {};
}

pub export fn editBufferMoveCursorLeft(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.moveLeft();
}

pub export fn editBufferMoveCursorRight(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.moveRight();
}

pub export fn editBufferMoveCursorUp(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.moveUp();
}

pub export fn editBufferMoveCursorDown(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.moveDown();
}

pub export fn editBufferGetCursor(edit_buffer: *edit_buffer_mod.EditBuffer, outRow: *u32, outCol: *u32) void {
    const cursor = edit_buffer.getPrimaryCursor();
    outRow.* = cursor.row;
    outCol.* = cursor.col;
}

pub export fn editBufferSetCursor(edit_buffer: *edit_buffer_mod.EditBuffer, row: u32, col: u32) void {
    edit_buffer.setCursor(row, col) catch {};
}

pub export fn editBufferSetCursorToLineCol(edit_buffer: *edit_buffer_mod.EditBuffer, row: u32, col: u32) void {
    edit_buffer.setCursor(row, col) catch {};
}

pub export fn editBufferSetCursorByOffset(edit_buffer: *edit_buffer_mod.EditBuffer, offset: u32) void {
    edit_buffer.setCursorByOffset(offset) catch {};
}

pub export fn editBufferGetNextWordBoundary(edit_buffer: *edit_buffer_mod.EditBuffer, outPtr: *ExternalLogicalCursor) void {
    const cursor = edit_buffer.getNextWordBoundary();
    outPtr.* = .{
        .row = cursor.row,
        .col = cursor.col,
        .offset = cursor.offset,
    };
}

pub export fn editBufferGetPrevWordBoundary(edit_buffer: *edit_buffer_mod.EditBuffer, outPtr: *ExternalLogicalCursor) void {
    const cursor = edit_buffer.getPrevWordBoundary();
    outPtr.* = .{
        .row = cursor.row,
        .col = cursor.col,
        .offset = cursor.offset,
    };
}

pub export fn editBufferGetEOL(edit_buffer: *edit_buffer_mod.EditBuffer, outPtr: *ExternalLogicalCursor) void {
    const cursor = edit_buffer.getEOL();
    outPtr.* = .{
        .row = cursor.row,
        .col = cursor.col,
        .offset = cursor.offset,
    };
}

pub export fn editBufferOffsetToPosition(edit_buffer: *edit_buffer_mod.EditBuffer, offset: u32, outPtr: *ExternalLogicalCursor) bool {
    const iter_mod = @import("text-buffer-iterators.zig");
    const coords = iter_mod.offsetToCoords(&edit_buffer.tb.rope, offset) orelse return false;
    outPtr.* = .{
        .row = coords.row,
        .col = coords.col,
        .offset = offset,
    };
    return true;
}

pub export fn editBufferPositionToOffset(edit_buffer: *edit_buffer_mod.EditBuffer, row: u32, col: u32) u32 {
    const iter_mod = @import("text-buffer-iterators.zig");
    return iter_mod.coordsToOffset(&edit_buffer.tb.rope, row, col) orelse 0;
}

pub export fn editBufferGetLineStartOffset(edit_buffer: *edit_buffer_mod.EditBuffer, row: u32) u32 {
    const iter_mod = @import("text-buffer-iterators.zig");
    return iter_mod.coordsToOffset(&edit_buffer.tb.rope, row, 0) orelse 0;
}

pub export fn editBufferGetTextRange(edit_buffer: *edit_buffer_mod.EditBuffer, start_offset: u32, end_offset: u32, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return edit_buffer.getTextRange(start_offset, end_offset, outBuffer) catch 0;
}

pub export fn editBufferGetTextRangeByCoords(edit_buffer: *edit_buffer_mod.EditBuffer, start_row: u32, start_col: u32, end_row: u32, end_col: u32, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return edit_buffer.getTextRangeByCoords(start_row, start_col, end_row, end_col, outBuffer);
}

pub export fn editBufferSetText(edit_buffer: *edit_buffer_mod.EditBuffer, textPtr: [*]const u8, textLen: usize) void {
    const text = textPtr[0..textLen];
    edit_buffer.setText(text) catch {};
}

pub export fn editBufferSetTextFromMem(edit_buffer: *edit_buffer_mod.EditBuffer, mem_id: u8) void {
    edit_buffer.setTextFromMemId(mem_id) catch {};
}

pub export fn editBufferReplaceText(edit_buffer: *edit_buffer_mod.EditBuffer, textPtr: [*]const u8, textLen: usize) void {
    const text = textPtr[0..textLen];
    edit_buffer.replaceText(text) catch {};
}

pub export fn editBufferReplaceTextFromMem(edit_buffer: *edit_buffer_mod.EditBuffer, mem_id: u8) void {
    edit_buffer.replaceTextFromMemId(mem_id) catch {};
}

pub export fn editBufferGetText(edit_buffer: *edit_buffer_mod.EditBuffer, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return edit_buffer.getText(outBuffer);
}

pub export fn editBufferInsertChar(edit_buffer: *edit_buffer_mod.EditBuffer, charPtr: [*]const u8, charLen: usize) void {
    const text = charPtr[0..charLen];
    edit_buffer.insertText(text) catch {};
}

pub export fn editBufferNewLine(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.insertText("\n") catch {};
}

pub export fn editBufferDeleteLine(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.deleteLine() catch {};
}

pub export fn editBufferGotoLine(edit_buffer: *edit_buffer_mod.EditBuffer, line: u32) void {
    edit_buffer.gotoLine(line) catch {};
}

pub export fn editBufferGetCursorPosition(edit_buffer: *edit_buffer_mod.EditBuffer, outPtr: *ExternalLogicalCursor) void {
    const pos = edit_buffer.getCursorPosition();
    outPtr.* = .{
        .row = pos.line,
        .col = pos.visual_col,
        .offset = pos.offset,
    };
}

pub export fn editBufferGetId(edit_buffer: *edit_buffer_mod.EditBuffer) u16 {
    return edit_buffer.getId();
}

pub export fn editBufferDebugLogRope(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.debugLogRope();
}

pub export fn editBufferUndo(edit_buffer: *edit_buffer_mod.EditBuffer, outPtr: [*]u8, maxLen: usize) usize {
    const prev_meta = edit_buffer.undo() catch return 0;
    const copyLen = @min(prev_meta.len, maxLen);
    @memcpy(outPtr[0..copyLen], prev_meta[0..copyLen]);
    return copyLen;
}

pub export fn editBufferRedo(edit_buffer: *edit_buffer_mod.EditBuffer, outPtr: [*]u8, maxLen: usize) usize {
    const next_meta = edit_buffer.redo() catch return 0;
    const copyLen = @min(next_meta.len, maxLen);
    @memcpy(outPtr[0..copyLen], next_meta[0..copyLen]);
    return copyLen;
}

pub export fn editBufferCanUndo(edit_buffer: *edit_buffer_mod.EditBuffer) bool {
    return edit_buffer.canUndo();
}

pub export fn editBufferCanRedo(edit_buffer: *edit_buffer_mod.EditBuffer) bool {
    return edit_buffer.canRedo();
}

pub export fn editBufferClearHistory(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.clearHistory();
}

pub export fn editBufferClear(edit_buffer: *edit_buffer_mod.EditBuffer) void {
    edit_buffer.clear() catch {};
}

// ===== EditorView Exports =====

pub export fn createEditorView(edit_buffer: *edit_buffer_mod.EditBuffer, viewport_width: u32, viewport_height: u32) ?*editor_view.EditorView {
    return editor_view.EditorView.init(globalArena, edit_buffer, viewport_width, viewport_height) catch null;
}

pub export fn destroyEditorView(view: *editor_view.EditorView) void {
    view.deinit();
}

pub export fn editorViewSetViewport(view: *editor_view.EditorView, x: u32, y: u32, width: u32, height: u32, moveCursor: bool) void {
    view.setViewport(text_buffer_view.Viewport{ .x = x, .y = y, .width = width, .height = height }, moveCursor);
}

pub export fn editorViewClearViewport(view: *editor_view.EditorView) void {
    view.setViewport(null, false);
}

pub export fn editorViewGetViewport(view: *editor_view.EditorView, outX: *u32, outY: *u32, outWidth: *u32, outHeight: *u32) bool {
    if (view.getViewport()) |vp| {
        outX.* = vp.x;
        outY.* = vp.y;
        outWidth.* = vp.width;
        outHeight.* = vp.height;
        return true;
    }
    return false;
}

pub export fn editorViewSetScrollMargin(view: *editor_view.EditorView, margin: f32) void {
    view.setScrollMargin(margin);
}

pub export fn editorViewGetVirtualLineCount(view: *editor_view.EditorView) u32 {
    // TODO: There is a getter for that directly, no?
    return @intCast(view.getVirtualLines().len);
}

pub export fn editorViewGetTotalVirtualLineCount(view: *editor_view.EditorView) u32 {
    return view.getTotalVirtualLineCount();
}

pub export fn editorViewGetLineInfoDirect(view: *editor_view.EditorView, outPtr: *ExternalLineInfo) void {
    const line_info = view.getCachedLineInfo();
    outPtr.* = .{
        .starts_ptr = line_info.starts.ptr,
        .starts_len = @intCast(line_info.starts.len),
        .widths_ptr = line_info.widths.ptr,
        .widths_len = @intCast(line_info.widths.len),
        .sources_ptr = line_info.sources.ptr,
        .sources_len = @intCast(line_info.sources.len),
        .wraps_ptr = line_info.wraps.ptr,
        .wraps_len = @intCast(line_info.wraps.len),
        .max_width = line_info.max_width,
    };
}

pub export fn editorViewGetTextBufferView(view: *editor_view.EditorView) *text_buffer_view.UnifiedTextBufferView {
    return view.getTextBufferView();
}

pub export fn editorViewGetLogicalLineInfoDirect(view: *editor_view.EditorView, outPtr: *ExternalLineInfo) void {
    const line_info = view.getLogicalLineInfo();
    outPtr.* = .{
        .starts_ptr = line_info.starts.ptr,
        .starts_len = @intCast(line_info.starts.len),
        .widths_ptr = line_info.widths.ptr,
        .widths_len = @intCast(line_info.widths.len),
        .sources_ptr = line_info.sources.ptr,
        .sources_len = @intCast(line_info.sources.len),
        .wraps_ptr = line_info.wraps.ptr,
        .wraps_len = @intCast(line_info.wraps.len),
        .max_width = line_info.max_width,
    };
}

pub export fn editorViewSetViewportSize(view: *editor_view.EditorView, width: u32, height: u32) void {
    view.setViewportSize(width, height);
}

pub export fn editorViewSetWrapMode(view: *editor_view.EditorView, mode: u8) void {
    const wrapMode: text_buffer.WrapMode = switch (mode) {
        0 => .none,
        1 => .char,
        2 => .word,
        else => .none,
    };
    view.setWrapMode(wrapMode);
}

// EditorView selection methods - delegate to TextBufferView
pub export fn editorViewSetSelection(view: *editor_view.EditorView, start: u32, end: u32, bgColor: ?[*]const f32, fgColor: ?[*]const f32) void {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    view.text_buffer_view.setSelection(start, end, bg, fg);
}

pub export fn editorViewResetSelection(view: *editor_view.EditorView) void {
    view.text_buffer_view.resetSelection();
}

pub export fn editorViewGetSelection(view: *editor_view.EditorView) u64 {
    return view.text_buffer_view.packSelectionInfo();
}

pub export fn editorViewSetLocalSelection(view: *editor_view.EditorView, anchorX: i32, anchorY: i32, focusX: i32, focusY: i32, bgColor: ?[*]const f32, fgColor: ?[*]const f32, updateCursor: bool, followCursor: bool) bool {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    view.setSelectionFollowCursor(followCursor);
    return view.setLocalSelection(anchorX, anchorY, focusX, focusY, bg, fg, updateCursor);
}

pub export fn editorViewUpdateSelection(view: *editor_view.EditorView, end: u32, bgColor: ?[*]const f32, fgColor: ?[*]const f32) void {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    view.updateSelection(end, bg, fg);
}

pub export fn editorViewUpdateLocalSelection(view: *editor_view.EditorView, anchorX: i32, anchorY: i32, focusX: i32, focusY: i32, bgColor: ?[*]const f32, fgColor: ?[*]const f32, updateCursor: bool, followCursor: bool) bool {
    const bg = if (bgColor) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    const fg = if (fgColor) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    view.setSelectionFollowCursor(followCursor);
    return view.updateLocalSelection(anchorX, anchorY, focusX, focusY, bg, fg, updateCursor);
}

pub export fn editorViewResetLocalSelection(view: *editor_view.EditorView) void {
    view.setSelectionFollowCursor(false);
    view.text_buffer_view.resetLocalSelection();
}

pub export fn editorViewGetSelectedTextBytes(view: *editor_view.EditorView, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return view.text_buffer_view.getSelectedTextIntoBuffer(outBuffer);
}

// EditorView cursor and text methods
pub export fn editorViewGetCursor(view: *editor_view.EditorView, outRow: *u32, outCol: *u32) void {
    const cursor = view.getPrimaryCursor();
    outRow.* = cursor.row;
    outCol.* = cursor.col;
}

pub export fn editorViewGetText(view: *editor_view.EditorView, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return view.getText(outBuffer);
}

// ===== EditorView VisualCursor Exports =====

pub export fn editorViewGetVisualCursor(view: *editor_view.EditorView, outPtr: *ExternalVisualCursor) void {
    const vcursor = view.getVisualCursor();
    outPtr.* = .{
        .visual_row = vcursor.visual_row,
        .visual_col = vcursor.visual_col,
        .logical_row = vcursor.logical_row,
        .logical_col = vcursor.logical_col,
        .offset = vcursor.offset,
    };
}

pub export fn editorViewMoveUpVisual(view: *editor_view.EditorView) void {
    view.moveUpVisual();
}

pub export fn editorViewMoveDownVisual(view: *editor_view.EditorView) void {
    view.moveDownVisual();
}

pub export fn editorViewDeleteSelectedText(view: *editor_view.EditorView) void {
    view.deleteSelectedText() catch {};
}

pub export fn editorViewSetCursorByOffset(view: *editor_view.EditorView, offset: u32) void {
    view.setCursorByOffset(offset) catch {};
}

pub export fn editorViewGetNextWordBoundary(view: *editor_view.EditorView, outPtr: *ExternalVisualCursor) void {
    const vcursor = view.getNextWordBoundary();
    outPtr.* = .{
        .visual_row = vcursor.visual_row,
        .visual_col = vcursor.visual_col,
        .logical_row = vcursor.logical_row,
        .logical_col = vcursor.logical_col,
        .offset = vcursor.offset,
    };
}

pub export fn editorViewGetPrevWordBoundary(view: *editor_view.EditorView, outPtr: *ExternalVisualCursor) void {
    const vcursor = view.getPrevWordBoundary();
    outPtr.* = .{
        .visual_row = vcursor.visual_row,
        .visual_col = vcursor.visual_col,
        .logical_row = vcursor.logical_row,
        .logical_col = vcursor.logical_col,
        .offset = vcursor.offset,
    };
}

pub export fn editorViewGetEOL(view: *editor_view.EditorView, outPtr: *ExternalVisualCursor) void {
    const vcursor = view.getEOL();
    outPtr.* = .{
        .visual_row = vcursor.visual_row,
        .visual_col = vcursor.visual_col,
        .logical_row = vcursor.logical_row,
        .logical_col = vcursor.logical_col,
        .offset = vcursor.offset,
    };
}

pub export fn editorViewGetVisualSOL(view: *editor_view.EditorView, outPtr: *ExternalVisualCursor) void {
    const vcursor = view.getVisualSOL();
    outPtr.* = .{
        .visual_row = vcursor.visual_row,
        .visual_col = vcursor.visual_col,
        .logical_row = vcursor.logical_row,
        .logical_col = vcursor.logical_col,
        .offset = vcursor.offset,
    };
}

pub export fn editorViewGetVisualEOL(view: *editor_view.EditorView, outPtr: *ExternalVisualCursor) void {
    const vcursor = view.getVisualEOL();
    outPtr.* = .{
        .visual_row = vcursor.visual_row,
        .visual_col = vcursor.visual_col,
        .logical_row = vcursor.logical_row,
        .logical_col = vcursor.logical_col,
        .offset = vcursor.offset,
    };
}

pub export fn editorViewSetPlaceholderStyledText(
    view: *editor_view.EditorView,
    chunksPtr: [*]const text_buffer.StyledChunk,
    chunkCount: usize,
) void {
    if (chunkCount == 0) {
        view.setPlaceholderStyledText(&[_]text_buffer.StyledChunk{}) catch {};
        return;
    }
    const chunks = chunksPtr[0..chunkCount];
    view.setPlaceholderStyledText(chunks) catch {};
}

pub export fn editorViewSetTabIndicator(view: *editor_view.EditorView, indicator: u32) void {
    view.setTabIndicator(indicator);
}

pub export fn editorViewSetTabIndicatorColor(view: *editor_view.EditorView, color: [*]const f32) void {
    view.setTabIndicatorColor(utils.f32PtrToRGBA(color));
}

pub export fn bufferDrawEditorView(
    bufferPtr: *buffer.OptimizedBuffer,
    viewPtr: *editor_view.EditorView,
    x: i32,
    y: i32,
) void {
    bufferPtr.drawEditorView(viewPtr, x, y) catch {};
}

pub export fn bufferDrawTextBufferView(
    bufferPtr: *buffer.OptimizedBuffer,
    viewPtr: *text_buffer_view.UnifiedTextBufferView,
    x: i32,
    y: i32,
) void {
    bufferPtr.drawTextBuffer(viewPtr, x, y) catch {};
}

pub const ExternalHighlight = extern struct {
    start: u32,
    end: u32,
    style_id: u32,
    priority: u8,
    hl_ref: u16,
};

pub const ExternalLogicalCursor = extern struct {
    row: u32,
    col: u32,
    offset: u32,
};

pub const ExternalVisualCursor = extern struct {
    visual_row: u32,
    visual_col: u32,
    logical_row: u32,
    logical_col: u32,
    offset: u32,
};

pub const ExternalLineInfo = extern struct {
    starts_ptr: [*]const u32,
    starts_len: u32,
    widths_ptr: [*]const u32,
    widths_len: u32,
    sources_ptr: [*]const u32,
    sources_len: u32,
    wraps_ptr: [*]const u32,
    wraps_len: u32,
    max_width: u32,
};

pub export fn textBufferAddHighlightByCharRange(
    tb: *text_buffer.UnifiedTextBuffer,
    hl_ptr: [*]const ExternalHighlight,
) void {
    const hl = hl_ptr[0];
    // For char-range highlights, start/end in the struct are unused (passed as char_start/char_end)
    tb.addHighlightByCharRange(hl.start, hl.end, hl.style_id, hl.priority, hl.hl_ref) catch {};
}

pub export fn textBufferAddHighlight(
    tb: *text_buffer.UnifiedTextBuffer,
    line_idx: u32,
    hl_ptr: [*]const ExternalHighlight,
) void {
    const hl = hl_ptr[0];
    // For line-based highlights, start/end are column offsets
    tb.addHighlight(line_idx, hl.start, hl.end, hl.style_id, hl.priority, hl.hl_ref) catch {};
}

pub export fn textBufferRemoveHighlightsByRef(tb: *text_buffer.UnifiedTextBuffer, hl_ref: u16) void {
    tb.removeHighlightsByRef(hl_ref);
}

pub export fn textBufferClearLineHighlights(tb: *text_buffer.UnifiedTextBuffer, line_idx: u32) void {
    tb.clearLineHighlights(line_idx);
}

pub export fn textBufferClearAllHighlights(tb: *text_buffer.UnifiedTextBuffer) void {
    tb.clearAllHighlights();
}

pub export fn textBufferSetSyntaxStyle(tb: *text_buffer.UnifiedTextBuffer, style: ?*syntax_style.SyntaxStyle) void {
    tb.setSyntaxStyle(style);
}

pub export fn textBufferGetLineHighlightsPtr(
    tb: *text_buffer.UnifiedTextBuffer,
    line_idx: u32,
    out_count: *usize,
) ?[*]const ExternalHighlight {
    const highs = tb.getLineHighlightsSlice(line_idx);

    if (highs.len == 0) {
        out_count.* = 0;
        return null;
    }

    var slice = globalAllocator.alloc(ExternalHighlight, highs.len) catch return null;

    for (highs, 0..) |hl, i| {
        slice[i] = .{
            .start = hl.col_start,
            .end = hl.col_end,
            .style_id = hl.style_id,
            .priority = hl.priority,
            .hl_ref = hl.hl_ref,
        };
    }

    out_count.* = highs.len;
    return slice.ptr;
}

pub export fn textBufferFreeLineHighlights(ptr: [*]const ExternalHighlight, count: usize) void {
    globalAllocator.free(@constCast(ptr)[0..count]);
}

pub export fn textBufferGetHighlightCount(tb: *text_buffer.UnifiedTextBuffer) u32 {
    return tb.getHighlightCount();
}

pub export fn textBufferGetTextRange(tb: *text_buffer.UnifiedTextBuffer, start_offset: u32, end_offset: u32, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return tb.getTextRange(start_offset, end_offset, outBuffer);
}

pub export fn textBufferGetTextRangeByCoords(tb: *text_buffer.UnifiedTextBuffer, start_row: u32, start_col: u32, end_row: u32, end_col: u32, outPtr: [*]u8, maxLen: usize) usize {
    const outBuffer = outPtr[0..maxLen];
    return tb.getTextRangeByCoords(start_row, start_col, end_row, end_col, outBuffer);
}

// SyntaxStyle functions
pub export fn createSyntaxStyle() ?*syntax_style.SyntaxStyle {
    return syntax_style.SyntaxStyle.init(globalAllocator) catch |err| {
        logger.err("Failed to create SyntaxStyle: {}", .{err});
        return null;
    };
}

pub export fn destroySyntaxStyle(style: *syntax_style.SyntaxStyle) void {
    style.deinit();
}

pub export fn syntaxStyleRegister(style: *syntax_style.SyntaxStyle, namePtr: [*]const u8, nameLen: usize, fg: ?[*]const f32, bg: ?[*]const f32, attributes: u32) u32 {
    const name = namePtr[0..nameLen];
    const fgColor = if (fg) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
    const bgColor = if (bg) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;
    return style.registerStyle(name, fgColor, bgColor, attributes) catch 0;
}

pub export fn syntaxStyleResolveByName(style: *syntax_style.SyntaxStyle, namePtr: [*]const u8, nameLen: usize) u32 {
    const name = namePtr[0..nameLen];
    return style.resolveByName(name) orelse 0;
}

pub export fn syntaxStyleGetStyleCount(style: *syntax_style.SyntaxStyle) usize {
    return style.getStyleCount();
}

// Unicode encoding API

pub const EncodedChar = extern struct {
    width: u8,
    char: u32,
};

pub export fn encodeUnicode(
    textPtr: [*]const u8,
    textLen: usize,
    outPtr: *[*]EncodedChar,
    outLenPtr: *usize,
    widthMethod: u8,
) bool {
    const text = textPtr[0..textLen];
    const pool = gp.initGlobalPool(globalArena);
    const wMethod: utf8.WidthMethod = if (widthMethod == 0) .wcwidth else .unicode;

    // Check if ASCII only for optimization
    const is_ascii_only = utf8.isAsciiOnly(text);

    // Find grapheme info
    var grapheme_list: std.ArrayListUnmanaged(utf8.GraphemeInfo) = .{};
    defer grapheme_list.deinit(globalAllocator);

    const tab_width: u8 = 2;
    utf8.findGraphemeInfo(text, tab_width, is_ascii_only, wMethod, globalAllocator, &grapheme_list) catch return false;
    const specials = grapheme_list.items;

    // Allocate output array
    const estimated_count = if (is_ascii_only) text.len else text.len * 2;
    var result = globalAllocator.alloc(EncodedChar, estimated_count) catch return false;
    var result_idx: usize = 0;
    var success = false;
    var pending_gid: ?u32 = null; // Track grapheme allocated but not yet stored in result

    // Clean up result array and any allocated grapheme IDs on failure
    defer {
        if (!success) {
            // Clean up pending grapheme that wasn't stored yet
            if (pending_gid) |gid| {
                // Try decref first (works if incref was called, refcount >= 1)
                // If that fails (refcount was 0), use freeUnreferenced
                pool.decref(gid) catch {
                    pool.freeUnreferenced(gid) catch {};
                };
            }
            // Decref any grapheme IDs we allocated before the failure
            for (result[0..result_idx]) |encoded_char| {
                if (gp.isGraphemeChar(encoded_char.char)) {
                    const gid = gp.graphemeIdFromChar(encoded_char.char);
                    pool.decref(gid) catch {};
                }
            }
            globalAllocator.free(result);
        }
    }

    var byte_offset: u32 = 0;
    var col: u32 = 0;
    var special_idx: usize = 0;

    while (byte_offset < text.len) {
        const at_special = special_idx < specials.len and specials[special_idx].col_offset == col;

        var grapheme_bytes: []const u8 = undefined;
        var g_width: u8 = undefined;

        if (at_special) {
            const g = specials[special_idx];
            grapheme_bytes = text[g.byte_offset .. g.byte_offset + g.byte_len];
            g_width = g.width;
            byte_offset = g.byte_offset + g.byte_len;
            special_idx += 1;
        } else {
            if (byte_offset >= text.len) break;
            grapheme_bytes = text[byte_offset .. byte_offset + 1];
            g_width = 1;
            byte_offset += 1;
        }

        const cell_width = utf8.getWidthAt(text, if (at_special) specials[special_idx - 1].byte_offset else byte_offset - 1, tab_width, wMethod);
        if (cell_width == 0) {
            col += g_width;
            continue;
        }

        // Encode the character
        var encoded_char: u32 = 0;
        if (grapheme_bytes.len == 1 and cell_width == 1 and grapheme_bytes[0] >= 32) {
            // Simple ASCII character
            encoded_char = @as(u32, grapheme_bytes[0]);
        } else {
            // Multi-byte or special character - allocate in pool
            const gid = pool.alloc(grapheme_bytes) catch return false;
            pending_gid = gid; // Track until stored in result
            encoded_char = gp.packGraphemeStart(gid & gp.GRAPHEME_ID_MASK, cell_width);

            // Incref since we're handing this off to the caller
            // Note: incref can only fail if gid is invalid, which shouldn't happen
            // for a freshly allocated gid. If it does fail, the slot leaks but
            // this is an edge case that indicates a bug elsewhere.
            pool.incref(gid) catch return false;
        }

        // Ensure we have space
        if (result_idx >= result.len) {
            const new_len = result.len * 2;
            result = globalAllocator.realloc(result, new_len) catch return false;
        }

        result[result_idx] = EncodedChar{
            .width = @intCast(cell_width),
            .char = encoded_char,
        };
        pending_gid = null; // Successfully stored, no longer pending
        result_idx += 1;
        col += g_width;
    }

    // Trim to actual size
    result = globalAllocator.realloc(result, result_idx) catch result;

    outPtr.* = result.ptr;
    outLenPtr.* = result_idx;
    success = true;
    return true;
}

pub export fn freeUnicode(charsPtr: [*]const EncodedChar, charsLen: usize) void {
    const chars = charsPtr[0..charsLen];
    const pool = gp.initGlobalPool(globalArena);

    for (chars) |encoded_char| {
        const char = encoded_char.char;

        // Check if this is a packed grapheme
        if (gp.isGraphemeChar(char)) {
            const gid = gp.graphemeIdFromChar(char);
            pool.decref(gid) catch {};
        }
    }

    // Free the array itself
    globalAllocator.free(chars);
}

pub export fn bufferDrawChar(
    bufferPtr: *buffer.OptimizedBuffer,
    char: u32,
    x: u32,
    y: u32,
    fg: [*]const f32,
    bg: [*]const f32,
    attributes: u32,
) void {
    const rgbaFg = utils.f32PtrToRGBA(fg);
    const rgbaBg = utils.f32PtrToRGBA(bg);
    bufferPtr.drawChar(char, x, y, rgbaFg, rgbaBg, attributes) catch {};
}
