const std = @import("std");
const napi = @import("napi");
const lib = @import("lib");

const CliRenderer = lib.CliRenderer;
const OptimizedBuffer = lib.OptimizedBuffer;
const RGBA = lib.RGBA;
const TextBufferView = lib.TextBufferView;
const EditorView = lib.EditorView;

var callback_env: ?napi.Env = null;
var log_callback: ?napi.Value = null;
var event_callback: ?napi.Value = null;

comptime {
    napi.registerModule(init);
}

fn ptrToValue(env: napi.Env, ptr: anytype) !napi.Value {
    const addr = @intFromPtr(ptr);
    const max_safe: usize = 9007199254740991;
    if (addr > max_safe) {
        return error.PointerExceedsSafeInteger;
    }
    const addr_f64: f64 = @floatFromInt(addr);
    return try napi.Value.createFrom(f64, env, addr_f64);
}

fn valueToPtr(comptime T: type, val: napi.Value) !T {
    const num = try val.getValue(f64);
    if (std.math.isNan(num) or std.math.isInf(num)) {
        return error.InvalidPointer;
    }
    if (num < 0 or @floor(num) != num) {
        return error.InvalidPointer;
    }
    const max_usize: f64 = @floatFromInt(std.math.maxInt(usize));
    if (num > max_usize) {
        return error.InvalidPointer;
    }
    const addr: usize = @intFromFloat(num);
    return @ptrFromInt(addr);
}

fn optionalPtrToValue(env: napi.Env, ptr: anytype) !napi.Value {
    if (ptr) |p| {
        return try ptrToValue(env, p);
    }
    return try env.getNull();
}

fn extractFloat32Array(val: napi.Value, comptime size: usize) ![size]f32 {
    var result: [size]f32 = undefined;
    for (0..size) |i| {
        const element = try val.getElement(@intCast(i));
        const value_f64 = try element.getValue(f64);
        result[i] = @floatCast(value_f64);
    }
    return result;
}

fn extractU32(val: napi.Value) !u32 {
    return try val.getValue(u32);
}

fn extractU8(val: napi.Value) !u8 {
    const value = try val.getValue(u32);
    return @intCast(value);
}

fn extractI32(val: napi.Value) !i32 {
    return try val.getValue(i32);
}

fn extractI64(val: napi.Value) !i64 {
    return try val.getValue(i64);
}

fn extractF64(val: napi.Value) !f64 {
    return try val.getValue(f64);
}

fn extractBool(val: napi.Value) !bool {
    return try val.getValue(bool);
}

fn extractUtf8Alloc(allocator: std.mem.Allocator, val: napi.Value) ![]u8 {
    var empty: [0]u8 = .{};
    const required_len = try val.getValueString(.utf8, empty[0..]);
    var bytes = try allocator.alloc(u8, required_len);
    const actual_len = try val.getValueString(.utf8, bytes);
    return bytes[0..actual_len];
}

fn extractBytesAlloc(allocator: std.mem.Allocator, val: napi.Value) ![]u8 {
    const value_type = try val.typeOf();
    if (value_type == .String) {
        return try extractUtf8Alloc(allocator, val);
    }

    const len_val = try val.getNamedProperty("length");
    const coerced_len = try len_val.coerceTo(.Number);
    const len_u32 = try coerced_len.getValue(u32);
    const len: usize = @intCast(len_u32);

    var bytes = try allocator.alloc(u8, len);
    for (0..len) |i| {
        const element = try val.getElement(@intCast(i));
        const number = try element.coerceTo(.Number);
        const number_u32 = try number.getValue(u32);
        bytes[i] = @truncate(number_u32);
    }
    return bytes;
}

fn rgbaFromValue(val: napi.Value) !RGBA {
    const f32_values = try extractFloat32Array(val, 4);
    return .{ f32_values[0], f32_values[1], f32_values[2], f32_values[3] };
}

fn optionalRgbaFromValue(val: napi.Value) !?RGBA {
    const value_type = try val.typeOf();
    if (value_type == .Null or value_type == .Undefined) {
        return null;
    }
    return try rgbaFromValue(val);
}

fn extractU32ArrayAlloc(allocator: std.mem.Allocator, val: napi.Value) ![]u32 {
    const len_val = try val.getNamedProperty("length");
    const coerced_len = try len_val.coerceTo(.Number);
    const len_u32 = try coerced_len.getValue(u32);
    const len: usize = @intCast(len_u32);

    var out = try allocator.alloc(u32, len);
    for (0..len) |i| {
        const element = try val.getElement(@intCast(i));
        const number = try element.coerceTo(.Number);
        out[i] = try number.getValue(u32);
    }
    return out;
}

fn bytesToArrayBuffer(env: napi.Env, bytes: []const u8) !napi.Value {
    var out_data: ?*anyopaque = null;
    const array_buffer = try napi.Value.createArrayBuffer(env, bytes.len, &out_data);
    if (bytes.len > 0 and out_data != null) {
        const out_ptr: [*]u8 = @ptrCast(out_data.?);
        std.mem.copyForwards(u8, out_ptr[0..bytes.len], bytes);
    }
    return array_buffer;
}

fn cursorStateToValue(env: napi.Env, state: lib.ExternalCursorState) !napi.Value {
    const obj = try env.createObject();
    try obj.setNamedProperty("x", try napi.Value.createFrom(u32, env, state.x));
    try obj.setNamedProperty("y", try napi.Value.createFrom(u32, env, state.y));
    try obj.setNamedProperty("visible", try env.getBoolean(state.visible));
    try obj.setNamedProperty("style", try napi.Value.createFrom(u32, env, state.style));
    try obj.setNamedProperty("blinking", try env.getBoolean(state.blinking));
    try obj.setNamedProperty("r", try napi.Value.createFrom(f64, env, state.r));
    try obj.setNamedProperty("g", try napi.Value.createFrom(f64, env, state.g));
    try obj.setNamedProperty("b", try napi.Value.createFrom(f64, env, state.b));
    try obj.setNamedProperty("a", try napi.Value.createFrom(f64, env, state.a));
    return obj;
}

fn callLogJs(level: u8, msg: []const u8) void {
    const env = callback_env orelse return;
    const cb = log_callback orelse return;

    const level_val = napi.Value.createFrom(u32, env, level) catch return;
    const message_val = env.createString(.utf8, msg) catch return;
    _ = cb.callFunction(2, null, .{ level_val, message_val }) catch {};
}

fn forwardLogCallback(level: u8, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void {
    const env = callback_env orelse return;
    const cb = log_callback orelse return;

    const msg = msg_ptr[0..msg_len];

    const level_val = napi.Value.createFrom(u32, env, level) catch return;
    const message_val = env.createString(.utf8, msg) catch return;
    _ = cb.callFunction(2, null, .{ level_val, message_val }) catch {};
}

fn forwardEventCallback(name_ptr: [*]const u8, name_len: usize, data_ptr: [*]const u8, data_len: usize) callconv(.c) void {
    const env = callback_env orelse return;
    const cb = event_callback orelse return;

    const name = name_ptr[0..name_len];
    const data = data_ptr[0..data_len];

    const name_val = env.createString(.utf8, name) catch return;
    const data_val = bytesToArrayBuffer(env, data) catch return;

    _ = cb.callFunction(2, null, .{ name_val, data_val }) catch {};
}

fn setLogCallback(env: napi.Env, callback_val: napi.Value) !napi.Value {
    const callback_type = try callback_val.typeOf();
    switch (callback_type) {
        .Null, .Undefined => {
            callback_env = env;
            log_callback = null;
            lib.setLogCallback(null);
        },
        .Function => {
            callback_env = env;
            log_callback = callback_val;
            lib.setLogCallback(&forwardLogCallback);
        },
        else => return error.InvalidCallback,
    }
    return try env.getNull();
}

fn setEventCallback(env: napi.Env, callback_val: napi.Value) !napi.Value {
    const callback_type = try callback_val.typeOf();
    switch (callback_type) {
        .Null, .Undefined => {
            callback_env = env;
            event_callback = null;
            lib.setEventCallback(null);
        },
        .Function => {
            callback_env = env;
            event_callback = callback_val;
            lib.setEventCallback(&forwardEventCallback);
        },
        else => return error.InvalidCallback,
    }
    return try env.getNull();
}

fn createRenderer(env: napi.Env, width_val: napi.Value, height_val: napi.Value, testing_val: napi.Value, remote_val: napi.Value) !napi.Value {
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    const testing = try extractBool(testing_val);
    const remote = try extractBool(remote_val);
    return optionalPtrToValue(env, lib.createRenderer(width, height, testing, remote));
}

fn destroyRenderer(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.destroyRenderer(renderer_ptr);
    return try env.getNull();
}

fn setUseThread(env: napi.Env, ptr_val: napi.Value, use_thread_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const use_thread = try extractBool(use_thread_val);
    lib.setUseThread(renderer_ptr, use_thread);
    return try env.getNull();
}

fn setBackgroundColor(env: napi.Env, ptr_val: napi.Value, color_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const color = try rgbaFromValue(color_val);
    lib.setBackgroundColor(renderer_ptr, @as([*]const f32, @ptrCast(&color)));
    return try env.getNull();
}

fn setRenderOffset(env: napi.Env, ptr_val: napi.Value, offset_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const offset = try extractU32(offset_val);
    lib.setRenderOffset(renderer_ptr, offset);
    return try env.getNull();
}

fn updateStats(env: napi.Env, ptr_val: napi.Value, time_val: napi.Value, fps_val: napi.Value, frame_callback_time_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const time = try extractF64(time_val);
    const fps = try extractU32(fps_val);
    const frame_callback_time = try extractF64(frame_callback_time_val);
    lib.updateStats(renderer_ptr, time, fps, frame_callback_time);
    return try env.getNull();
}

fn updateMemoryStats(env: napi.Env, ptr_val: napi.Value, heap_used_val: napi.Value, heap_total_val: napi.Value, array_buffers_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const heap_used = try extractU32(heap_used_val);
    const heap_total = try extractU32(heap_total_val);
    const array_buffers = try extractU32(array_buffers_val);
    lib.updateMemoryStats(renderer_ptr, heap_used, heap_total, array_buffers);
    return try env.getNull();
}

fn render(env: napi.Env, ptr_val: napi.Value, force_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const force = try extractBool(force_val);
    lib.render(renderer_ptr, force);
    return try env.getNull();
}

fn getNextBuffer(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    return try ptrToValue(env, lib.getNextBuffer(renderer_ptr));
}

fn getCurrentBuffer(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    return try ptrToValue(env, lib.getCurrentBuffer(renderer_ptr));
}

fn getBufferWidth(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const width = lib.getBufferWidth(buffer_ptr);
    return napi.Value.createFrom(u32, env, width);
}

fn getBufferHeight(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const height = lib.getBufferHeight(buffer_ptr);
    return napi.Value.createFrom(u32, env, height);
}

fn resizeRenderer(env: napi.Env, ptr_val: napi.Value, width_val: napi.Value, height_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    lib.resizeRenderer(renderer_ptr, width, height);
    return try env.getNull();
}

fn setCursorPosition(env: napi.Env, ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, visible_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    const visible = try extractBool(visible_val);
    lib.setCursorPosition(renderer_ptr, x, y, visible);
    return try env.getNull();
}

fn setCursorStyle(env: napi.Env, ptr_val: napi.Value, style_val: napi.Value, blinking_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const style = try extractUtf8Alloc(allocator, style_val);
    defer allocator.free(style);
    const blinking = try extractBool(blinking_val);
    lib.setCursorStyle(renderer_ptr, style.ptr, style.len, blinking);
    return try env.getNull();
}

fn setCursorColor(env: napi.Env, ptr_val: napi.Value, color_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const color = try rgbaFromValue(color_val);
    lib.setCursorColor(renderer_ptr, @as([*]const f32, @ptrCast(&color)));
    return try env.getNull();
}

fn getCursorState(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    var state: lib.ExternalCursorState = undefined;
    lib.getCursorState(renderer_ptr, &state);
    return cursorStateToValue(env, state);
}

fn setDebugOverlay(env: napi.Env, ptr_val: napi.Value, enabled_val: napi.Value, corner_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const enabled = try extractBool(enabled_val);
    const corner = try extractU8(corner_val);
    lib.setDebugOverlay(renderer_ptr, enabled, corner);
    return try env.getNull();
}

fn clearTerminal(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.clearTerminal(renderer_ptr);
    return try env.getNull();
}

fn setTerminalTitle(env: napi.Env, ptr_val: napi.Value, title_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const title = try extractUtf8Alloc(allocator, title_val);
    defer allocator.free(title);
    lib.setTerminalTitle(renderer_ptr, title.ptr, title.len);
    return try env.getNull();
}

fn copyToClipboardOSC52(env: napi.Env, ptr_val: napi.Value, target_val: napi.Value, payload_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const target = try extractU8(target_val);
    const payload = try extractBytesAlloc(allocator, payload_val);
    defer allocator.free(payload);

    const success = lib.copyToClipboardOSC52(renderer_ptr, target, payload.ptr, payload.len);
    return try env.getBoolean(success);
}

fn clearClipboardOSC52(env: napi.Env, ptr_val: napi.Value, target_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const target = try extractU8(target_val);
    const success = lib.clearClipboardOSC52(renderer_ptr, target);
    return try env.getBoolean(success);
}

fn addToHitGrid(env: napi.Env, ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, width_val: napi.Value, height_val: napi.Value, id_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    const id = try extractU32(id_val);
    lib.addToHitGrid(renderer_ptr, x, y, width, height, id);
    return try env.getNull();
}

fn clearCurrentHitGrid(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.clearCurrentHitGrid(renderer_ptr);
    return try env.getNull();
}

fn hitGridPushScissorRect(env: napi.Env, ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, width_val: napi.Value, height_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    lib.hitGridPushScissorRect(renderer_ptr, x, y, width, height);
    return try env.getNull();
}

fn hitGridPopScissorRect(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.hitGridPopScissorRect(renderer_ptr);
    return try env.getNull();
}

fn hitGridClearScissorRects(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.hitGridClearScissorRects(renderer_ptr);
    return try env.getNull();
}

fn addToCurrentHitGridClipped(env: napi.Env, ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, width_val: napi.Value, height_val: napi.Value, id_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    const id = try extractU32(id_val);
    lib.addToCurrentHitGridClipped(renderer_ptr, x, y, width, height, id);
    return try env.getNull();
}

fn checkHit(env: napi.Env, ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const x = try extractU32(x_val);
    const y = try extractU32(y_val);
    const id = lib.checkHit(renderer_ptr, x, y);
    return napi.Value.createFrom(u32, env, id);
}

fn getHitGridDirty(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const dirty = lib.getHitGridDirty(renderer_ptr);
    return try env.getBoolean(dirty);
}

fn dumpHitGrid(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.dumpHitGrid(renderer_ptr);
    return try env.getNull();
}

fn dumpBuffers(env: napi.Env, ptr_val: napi.Value, timestamp_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const timestamp = try extractI64(timestamp_val);
    lib.dumpBuffers(renderer_ptr, timestamp);
    return try env.getNull();
}

fn dumpStdoutBuffer(env: napi.Env, ptr_val: napi.Value, timestamp_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const timestamp = try extractI64(timestamp_val);
    lib.dumpStdoutBuffer(renderer_ptr, timestamp);
    return try env.getNull();
}

fn enableMouse(env: napi.Env, ptr_val: napi.Value, enable_movement_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const enable_movement = try extractBool(enable_movement_val);
    lib.enableMouse(renderer_ptr, enable_movement);
    return try env.getNull();
}

fn disableMouse(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.disableMouse(renderer_ptr);
    return try env.getNull();
}

fn enableKittyKeyboard(env: napi.Env, ptr_val: napi.Value, flags_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const flags = try extractU8(flags_val);
    lib.enableKittyKeyboard(renderer_ptr, flags);
    return try env.getNull();
}

fn disableKittyKeyboard(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.disableKittyKeyboard(renderer_ptr);
    return try env.getNull();
}

fn setKittyKeyboardFlags(env: napi.Env, ptr_val: napi.Value, flags_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const flags = try extractU8(flags_val);
    lib.setKittyKeyboardFlags(renderer_ptr, flags);
    return try env.getNull();
}

fn getKittyKeyboardFlags(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const flags = lib.getKittyKeyboardFlags(renderer_ptr);
    return napi.Value.createFrom(u32, env, flags);
}

fn setupTerminal(env: napi.Env, ptr_val: napi.Value, use_alt_screen_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const use_alt_screen = try extractBool(use_alt_screen_val);
    lib.setupTerminal(renderer_ptr, use_alt_screen);
    return try env.getNull();
}

fn suspendRenderer(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.suspendRenderer(renderer_ptr);
    return try env.getNull();
}

fn resumeRenderer(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.resumeRenderer(renderer_ptr);
    return try env.getNull();
}

fn queryPixelResolution(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.queryPixelResolution(renderer_ptr);
    return try env.getNull();
}

fn writeOut(env: napi.Env, ptr_val: napi.Value, data_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const bytes = try extractBytesAlloc(allocator, data_val);
    defer allocator.free(bytes);
    lib.writeOut(renderer_ptr, bytes.ptr, bytes.len);
    return try env.getNull();
}

fn bufferDrawChar(env: napi.Env, buffer_ptr_val: napi.Value, char_val: napi.Value, x_val: napi.Value, y_val: napi.Value, fg_val: napi.Value, bg_val: napi.Value, attributes_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const char = try extractU32(char_val);
    const x = try extractU32(x_val);
    const y = try extractU32(y_val);
    const fg = try rgbaFromValue(fg_val);
    const bg = try rgbaFromValue(bg_val);
    const attributes = try extractU32(attributes_val);

    lib.bufferDrawChar(buffer_ptr, char, x, y, &fg, &bg, attributes);
    return try env.getNull();
}

fn createOptimizedBuffer(env: napi.Env, width_val: napi.Value, height_val: napi.Value, respect_alpha_val: napi.Value, width_method_val: napi.Value, id_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    const respect_alpha = try extractBool(respect_alpha_val);
    const width_method = try extractU8(width_method_val);
    const id = try extractUtf8Alloc(allocator, id_val);
    defer allocator.free(id);

    return optionalPtrToValue(env, lib.createOptimizedBuffer(width, height, respect_alpha, width_method, id.ptr, id.len));
}

fn destroyOptimizedBuffer(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    lib.destroyOptimizedBuffer(buffer_ptr);
    return try env.getNull();
}

fn drawFrameBuffer(env: napi.Env, target_ptr_val: napi.Value, dest_x_val: napi.Value, dest_y_val: napi.Value, frame_ptr_val: napi.Value, source_x_val: napi.Value, source_y_val: napi.Value, source_width_val: napi.Value, source_height_val: napi.Value) !napi.Value {
    const target_ptr = try valueToPtr(*OptimizedBuffer, target_ptr_val);
    const dest_x = try extractI32(dest_x_val);
    const dest_y = try extractI32(dest_y_val);
    const frame_ptr = try valueToPtr(*OptimizedBuffer, frame_ptr_val);
    const source_x = try extractU32(source_x_val);
    const source_y = try extractU32(source_y_val);
    const source_width = try extractU32(source_width_val);
    const source_height = try extractU32(source_height_val);

    lib.drawFrameBuffer(target_ptr, dest_x, dest_y, frame_ptr, source_x, source_y, source_width, source_height);
    return try env.getNull();
}

fn bufferClear(env: napi.Env, buffer_ptr_val: napi.Value, bg_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const bg = try rgbaFromValue(bg_val);
    lib.bufferClear(buffer_ptr, @as([*]const f32, @ptrCast(&bg)));
    return try env.getNull();
}

fn bufferGetCharPtr(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    return try ptrToValue(env, lib.bufferGetCharPtr(buffer_ptr));
}

fn bufferGetFgPtr(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    return try ptrToValue(env, lib.bufferGetFgPtr(buffer_ptr));
}

fn bufferGetBgPtr(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    return try ptrToValue(env, lib.bufferGetBgPtr(buffer_ptr));
}

fn bufferGetAttributesPtr(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    return try ptrToValue(env, lib.bufferGetAttributesPtr(buffer_ptr));
}

fn bufferGetRespectAlpha(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    return try env.getBoolean(lib.bufferGetRespectAlpha(buffer_ptr));
}

fn bufferSetRespectAlpha(env: napi.Env, buffer_ptr_val: napi.Value, respect_alpha_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const respect_alpha = try extractBool(respect_alpha_val);
    lib.bufferSetRespectAlpha(buffer_ptr, respect_alpha);
    return try env.getNull();
}

fn bufferGetId(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    var out: [1024]u8 = undefined;
    const len = lib.bufferGetId(buffer_ptr, &out, out.len);
    return try env.createString(.utf8, out[0..len]);
}

fn bufferGetRealCharSize(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    return napi.Value.createFrom(u32, env, lib.bufferGetRealCharSize(buffer_ptr));
}

fn bufferWriteResolvedChars(env: napi.Env, buffer_ptr_val: napi.Value, output_buffer_val: napi.Value, add_line_breaks_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const add_line_breaks = try extractBool(add_line_breaks_val);

    const len_val = try output_buffer_val.getNamedProperty("length");
    const len_num = try (try len_val.coerceTo(.Number)).getValue(u32);
    const out_len: usize = @intCast(len_num);

    const temp = try allocator.alloc(u8, out_len);
    defer allocator.free(temp);

    const written = lib.bufferWriteResolvedChars(buffer_ptr, temp.ptr, temp.len, add_line_breaks);

    for (0..out_len) |i| {
        const byte_val = try napi.Value.createFrom(u32, env, @as(u32, temp[i]));
        try output_buffer_val.setElement(@intCast(i), byte_val);
    }

    return napi.Value.createFrom(u32, env, written);
}

fn bufferDrawText(env: napi.Env, buffer_ptr_val: napi.Value, text_val: napi.Value, x_val: napi.Value, y_val: napi.Value, fg_val: napi.Value, bg_val: napi.Value, attributes_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const text = try extractUtf8Alloc(allocator, text_val);
    defer allocator.free(text);
    const x = try extractU32(x_val);
    const y = try extractU32(y_val);
    const fg = try rgbaFromValue(fg_val);
    const bg_opt = try optionalRgbaFromValue(bg_val);
    const attributes = try extractU32(attributes_val);

    var bg_color: RGBA = undefined;
    const bg_ptr: ?[*]const f32 = if (bg_opt) |bg| blk: {
        bg_color = bg;
        break :blk @as([*]const f32, @ptrCast(&bg_color));
    } else null;

    lib.bufferDrawText(buffer_ptr, text.ptr, text.len, x, y, @as([*]const f32, @ptrCast(&fg)), bg_ptr, attributes);
    return try env.getNull();
}

fn bufferSetCellWithAlphaBlending(env: napi.Env, buffer_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, char_val: napi.Value, fg_val: napi.Value, bg_val: napi.Value, attributes_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const x = try extractU32(x_val);
    const y = try extractU32(y_val);
    const char = try extractU32(char_val);
    const fg = try rgbaFromValue(fg_val);
    const bg = try rgbaFromValue(bg_val);
    const attributes = try extractU32(attributes_val);

    lib.bufferSetCellWithAlphaBlending(buffer_ptr, x, y, char, @as([*]const f32, @ptrCast(&fg)), @as([*]const f32, @ptrCast(&bg)), attributes);
    return try env.getNull();
}

fn bufferSetCell(env: napi.Env, buffer_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, char_val: napi.Value, fg_val: napi.Value, bg_val: napi.Value, attributes_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const x = try extractU32(x_val);
    const y = try extractU32(y_val);
    const char = try extractU32(char_val);
    const fg = try rgbaFromValue(fg_val);
    const bg = try rgbaFromValue(bg_val);
    const attributes = try extractU32(attributes_val);

    lib.bufferSetCell(buffer_ptr, x, y, char, @as([*]const f32, @ptrCast(&fg)), @as([*]const f32, @ptrCast(&bg)), attributes);
    return try env.getNull();
}

fn bufferFillRect(env: napi.Env, buffer_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, width_val: napi.Value, height_val: napi.Value, bg_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const x = try extractU32(x_val);
    const y = try extractU32(y_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    const bg = try rgbaFromValue(bg_val);

    lib.bufferFillRect(buffer_ptr, x, y, width, height, @as([*]const f32, @ptrCast(&bg)));
    return try env.getNull();
}

fn bufferDrawSuperSampleBuffer(env: napi.Env, buffer_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, pixel_data_ptr_val: napi.Value, pixel_data_len_val: napi.Value, format_val: napi.Value, aligned_bytes_per_row_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const x = try extractU32(x_val);
    const y = try extractU32(y_val);
    const pixel_data_ptr = try valueToPtr([*]const u8, pixel_data_ptr_val);
    const pixel_data_len = try extractU32(pixel_data_len_val);
    const format = try extractU8(format_val);
    const aligned_bytes_per_row = try extractU32(aligned_bytes_per_row_val);

    lib.bufferDrawSuperSampleBuffer(buffer_ptr, x, y, pixel_data_ptr, pixel_data_len, format, aligned_bytes_per_row);
    return try env.getNull();
}

fn bufferDrawPackedBuffer(env: napi.Env, buffer_ptr_val: napi.Value, data_ptr_val: napi.Value, data_len_val: napi.Value, pos_x_val: napi.Value, pos_y_val: napi.Value, terminal_width_cells_val: napi.Value, terminal_height_cells_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const data_ptr = try valueToPtr([*]const u8, data_ptr_val);
    const data_len = try extractU32(data_len_val);
    const pos_x = try extractU32(pos_x_val);
    const pos_y = try extractU32(pos_y_val);
    const terminal_width_cells = try extractU32(terminal_width_cells_val);
    const terminal_height_cells = try extractU32(terminal_height_cells_val);

    lib.bufferDrawPackedBuffer(buffer_ptr, data_ptr, data_len, pos_x, pos_y, terminal_width_cells, terminal_height_cells);
    return try env.getNull();
}

fn bufferDrawGrayscaleBuffer(env: napi.Env, buffer_ptr_val: napi.Value, pos_x_val: napi.Value, pos_y_val: napi.Value, intensities_ptr_val: napi.Value, src_width_val: napi.Value, src_height_val: napi.Value, fg_val: napi.Value, bg_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const pos_x = try extractI32(pos_x_val);
    const pos_y = try extractI32(pos_y_val);
    const intensities_ptr = try valueToPtr([*]const f32, intensities_ptr_val);
    const src_width = try extractU32(src_width_val);
    const src_height = try extractU32(src_height_val);
    const fg_opt = try optionalRgbaFromValue(fg_val);
    const bg_opt = try optionalRgbaFromValue(bg_val);

    var fg_color: RGBA = undefined;
    var bg_color: RGBA = undefined;
    const fg_ptr: ?[*]const f32 = if (fg_opt) |fg| blk: {
        fg_color = fg;
        break :blk @as([*]const f32, @ptrCast(&fg_color));
    } else null;
    const bg_ptr: ?[*]const f32 = if (bg_opt) |bg| blk: {
        bg_color = bg;
        break :blk @as([*]const f32, @ptrCast(&bg_color));
    } else null;

    lib.bufferDrawGrayscaleBuffer(buffer_ptr, pos_x, pos_y, intensities_ptr, src_width, src_height, fg_ptr, bg_ptr);
    return try env.getNull();
}

fn bufferDrawGrayscaleBufferSupersampled(env: napi.Env, buffer_ptr_val: napi.Value, pos_x_val: napi.Value, pos_y_val: napi.Value, intensities_ptr_val: napi.Value, src_width_val: napi.Value, src_height_val: napi.Value, fg_val: napi.Value, bg_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const pos_x = try extractI32(pos_x_val);
    const pos_y = try extractI32(pos_y_val);
    const intensities_ptr = try valueToPtr([*]const f32, intensities_ptr_val);
    const src_width = try extractU32(src_width_val);
    const src_height = try extractU32(src_height_val);
    const fg_opt = try optionalRgbaFromValue(fg_val);
    const bg_opt = try optionalRgbaFromValue(bg_val);

    var fg_color: RGBA = undefined;
    var bg_color: RGBA = undefined;
    const fg_ptr: ?[*]const f32 = if (fg_opt) |fg| blk: {
        fg_color = fg;
        break :blk @as([*]const f32, @ptrCast(&fg_color));
    } else null;
    const bg_ptr: ?[*]const f32 = if (bg_opt) |bg| blk: {
        bg_color = bg;
        break :blk @as([*]const f32, @ptrCast(&bg_color));
    } else null;

    lib.bufferDrawGrayscaleBufferSupersampled(buffer_ptr, pos_x, pos_y, intensities_ptr, src_width, src_height, fg_ptr, bg_ptr);
    return try env.getNull();
}

fn bufferDrawBox(env: napi.Env, buffer_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, width_val: napi.Value, height_val: napi.Value, border_chars_val: napi.Value, packed_options_val: napi.Value, border_color_val: napi.Value, background_color_val: napi.Value, title_val: napi.Value) !napi.Value {
    const allocator = std.heap.page_allocator;
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    const border_chars = try extractU32ArrayAlloc(allocator, border_chars_val);
    defer allocator.free(border_chars);
    const packed_options = try extractU32(packed_options_val);
    const border_color = try rgbaFromValue(border_color_val);
    const background_color = try rgbaFromValue(background_color_val);

    const title_type = try title_val.typeOf();
    const title_bytes: ?[]u8 = if (title_type == .Null or title_type == .Undefined) null else try extractUtf8Alloc(allocator, title_val);
    defer if (title_bytes) |bytes| allocator.free(bytes);

    const title_ptr: ?[*]const u8 = if (title_bytes) |bytes| bytes.ptr else null;
    const title_len: u32 = if (title_bytes) |bytes| @intCast(bytes.len) else 0;

    lib.bufferDrawBox(
        buffer_ptr,
        x,
        y,
        width,
        height,
        border_chars.ptr,
        packed_options,
        @as([*]const f32, @ptrCast(&border_color)),
        @as([*]const f32, @ptrCast(&background_color)),
        title_ptr,
        title_len,
    );
    return try env.getNull();
}

fn bufferResize(env: napi.Env, buffer_ptr_val: napi.Value, width_val: napi.Value, height_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    lib.bufferResize(buffer_ptr, width, height);
    return try env.getNull();
}

fn bufferPushScissorRect(env: napi.Env, buffer_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value, width_val: napi.Value, height_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    const width = try extractU32(width_val);
    const height = try extractU32(height_val);
    lib.bufferPushScissorRect(buffer_ptr, x, y, width, height);
    return try env.getNull();
}

fn bufferPopScissorRect(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    lib.bufferPopScissorRect(buffer_ptr);
    return try env.getNull();
}

fn bufferClearScissorRects(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    lib.bufferClearScissorRects(buffer_ptr);
    return try env.getNull();
}

fn bufferPushOpacity(env: napi.Env, buffer_ptr_val: napi.Value, opacity_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const opacity_f64 = try extractF64(opacity_val);
    const opacity: f32 = @floatCast(opacity_f64);
    lib.bufferPushOpacity(buffer_ptr, opacity);
    return try env.getNull();
}

fn bufferPopOpacity(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    lib.bufferPopOpacity(buffer_ptr);
    return try env.getNull();
}

fn bufferGetCurrentOpacity(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const opacity = lib.bufferGetCurrentOpacity(buffer_ptr);
    return napi.Value.createFrom(f64, env, opacity);
}

fn bufferClearOpacity(env: napi.Env, buffer_ptr_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    lib.bufferClearOpacity(buffer_ptr);
    return try env.getNull();
}

fn bufferDrawTextBufferView(env: napi.Env, buffer_ptr_val: napi.Value, view_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const view_ptr = try valueToPtr(*TextBufferView, view_ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    lib.bufferDrawTextBufferView(buffer_ptr, view_ptr, x, y);
    return try env.getNull();
}

fn bufferDrawEditorView(env: napi.Env, buffer_ptr_val: napi.Value, view_ptr_val: napi.Value, x_val: napi.Value, y_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const view_ptr = try valueToPtr(*EditorView, view_ptr_val);
    const x = try extractI32(x_val);
    const y = try extractI32(y_val);
    lib.bufferDrawEditorView(buffer_ptr, view_ptr, x, y);
    return try env.getNull();
}

fn init(env: napi.Env, exports: napi.Value) !napi.Value {
    try exports.setNamedProperty("setLogCallback", try env.createFunction(setLogCallback, null));
    try exports.setNamedProperty("setEventCallback", try env.createFunction(setEventCallback, null));

    try exports.setNamedProperty("createRenderer", try env.createFunction(createRenderer, null));
    try exports.setNamedProperty("destroyRenderer", try env.createFunction(destroyRenderer, null));
    try exports.setNamedProperty("setUseThread", try env.createFunction(setUseThread, null));
    try exports.setNamedProperty("setBackgroundColor", try env.createFunction(setBackgroundColor, null));
    try exports.setNamedProperty("setRenderOffset", try env.createFunction(setRenderOffset, null));
    try exports.setNamedProperty("updateStats", try env.createFunction(updateStats, null));
    try exports.setNamedProperty("updateMemoryStats", try env.createFunction(updateMemoryStats, null));
    try exports.setNamedProperty("render", try env.createFunction(render, null));
    try exports.setNamedProperty("getNextBuffer", try env.createFunction(getNextBuffer, null));
    try exports.setNamedProperty("getCurrentBuffer", try env.createFunction(getCurrentBuffer, null));
    try exports.setNamedProperty("getBufferWidth", try env.createFunction(getBufferWidth, null));
    try exports.setNamedProperty("getBufferHeight", try env.createFunction(getBufferHeight, null));
    try exports.setNamedProperty("createOptimizedBuffer", try env.createFunction(createOptimizedBuffer, null));
    try exports.setNamedProperty("destroyOptimizedBuffer", try env.createFunction(destroyOptimizedBuffer, null));
    try exports.setNamedProperty("drawFrameBuffer", try env.createFunction(drawFrameBuffer, null));
    try exports.setNamedProperty("bufferClear", try env.createFunction(bufferClear, null));
    try exports.setNamedProperty("bufferGetCharPtr", try env.createFunction(bufferGetCharPtr, null));
    try exports.setNamedProperty("bufferGetFgPtr", try env.createFunction(bufferGetFgPtr, null));
    try exports.setNamedProperty("bufferGetBgPtr", try env.createFunction(bufferGetBgPtr, null));
    try exports.setNamedProperty("bufferGetAttributesPtr", try env.createFunction(bufferGetAttributesPtr, null));
    try exports.setNamedProperty("bufferGetRespectAlpha", try env.createFunction(bufferGetRespectAlpha, null));
    try exports.setNamedProperty("bufferSetRespectAlpha", try env.createFunction(bufferSetRespectAlpha, null));
    try exports.setNamedProperty("bufferGetId", try env.createFunction(bufferGetId, null));
    try exports.setNamedProperty("bufferGetRealCharSize", try env.createFunction(bufferGetRealCharSize, null));
    try exports.setNamedProperty("bufferWriteResolvedChars", try env.createFunction(bufferWriteResolvedChars, null));
    try exports.setNamedProperty("bufferDrawText", try env.createFunction(bufferDrawText, null));
    try exports.setNamedProperty("bufferSetCellWithAlphaBlending", try env.createFunction(bufferSetCellWithAlphaBlending, null));
    try exports.setNamedProperty("bufferSetCell", try env.createFunction(bufferSetCell, null));
    try exports.setNamedProperty("bufferFillRect", try env.createFunction(bufferFillRect, null));
    try exports.setNamedProperty("bufferDrawSuperSampleBuffer", try env.createFunction(bufferDrawSuperSampleBuffer, null));
    try exports.setNamedProperty("bufferDrawPackedBuffer", try env.createFunction(bufferDrawPackedBuffer, null));
    try exports.setNamedProperty("bufferDrawGrayscaleBuffer", try env.createFunction(bufferDrawGrayscaleBuffer, null));
    try exports.setNamedProperty("bufferDrawGrayscaleBufferSupersampled", try env.createFunction(bufferDrawGrayscaleBufferSupersampled, null));
    try exports.setNamedProperty("bufferDrawBox", try env.createFunction(bufferDrawBox, null));
    try exports.setNamedProperty("bufferResize", try env.createFunction(bufferResize, null));
    try exports.setNamedProperty("bufferPushScissorRect", try env.createFunction(bufferPushScissorRect, null));
    try exports.setNamedProperty("bufferPopScissorRect", try env.createFunction(bufferPopScissorRect, null));
    try exports.setNamedProperty("bufferClearScissorRects", try env.createFunction(bufferClearScissorRects, null));
    try exports.setNamedProperty("bufferPushOpacity", try env.createFunction(bufferPushOpacity, null));
    try exports.setNamedProperty("bufferPopOpacity", try env.createFunction(bufferPopOpacity, null));
    try exports.setNamedProperty("bufferGetCurrentOpacity", try env.createFunction(bufferGetCurrentOpacity, null));
    try exports.setNamedProperty("bufferClearOpacity", try env.createFunction(bufferClearOpacity, null));
    try exports.setNamedProperty("bufferDrawTextBufferView", try env.createFunction(bufferDrawTextBufferView, null));
    try exports.setNamedProperty("bufferDrawEditorView", try env.createFunction(bufferDrawEditorView, null));
    try exports.setNamedProperty("resizeRenderer", try env.createFunction(resizeRenderer, null));
    try exports.setNamedProperty("setCursorPosition", try env.createFunction(setCursorPosition, null));
    try exports.setNamedProperty("setCursorStyle", try env.createFunction(setCursorStyle, null));
    try exports.setNamedProperty("setCursorColor", try env.createFunction(setCursorColor, null));
    try exports.setNamedProperty("getCursorState", try env.createFunction(getCursorState, null));
    try exports.setNamedProperty("setDebugOverlay", try env.createFunction(setDebugOverlay, null));
    try exports.setNamedProperty("clearTerminal", try env.createFunction(clearTerminal, null));
    try exports.setNamedProperty("setTerminalTitle", try env.createFunction(setTerminalTitle, null));
    try exports.setNamedProperty("copyToClipboardOSC52", try env.createFunction(copyToClipboardOSC52, null));
    try exports.setNamedProperty("clearClipboardOSC52", try env.createFunction(clearClipboardOSC52, null));
    try exports.setNamedProperty("addToHitGrid", try env.createFunction(addToHitGrid, null));
    try exports.setNamedProperty("clearCurrentHitGrid", try env.createFunction(clearCurrentHitGrid, null));
    try exports.setNamedProperty("hitGridPushScissorRect", try env.createFunction(hitGridPushScissorRect, null));
    try exports.setNamedProperty("hitGridPopScissorRect", try env.createFunction(hitGridPopScissorRect, null));
    try exports.setNamedProperty("hitGridClearScissorRects", try env.createFunction(hitGridClearScissorRects, null));
    try exports.setNamedProperty("addToCurrentHitGridClipped", try env.createFunction(addToCurrentHitGridClipped, null));
    try exports.setNamedProperty("checkHit", try env.createFunction(checkHit, null));
    try exports.setNamedProperty("getHitGridDirty", try env.createFunction(getHitGridDirty, null));
    try exports.setNamedProperty("dumpHitGrid", try env.createFunction(dumpHitGrid, null));
    try exports.setNamedProperty("dumpBuffers", try env.createFunction(dumpBuffers, null));
    try exports.setNamedProperty("dumpStdoutBuffer", try env.createFunction(dumpStdoutBuffer, null));
    try exports.setNamedProperty("enableMouse", try env.createFunction(enableMouse, null));
    try exports.setNamedProperty("disableMouse", try env.createFunction(disableMouse, null));
    try exports.setNamedProperty("enableKittyKeyboard", try env.createFunction(enableKittyKeyboard, null));
    try exports.setNamedProperty("disableKittyKeyboard", try env.createFunction(disableKittyKeyboard, null));
    try exports.setNamedProperty("setKittyKeyboardFlags", try env.createFunction(setKittyKeyboardFlags, null));
    try exports.setNamedProperty("getKittyKeyboardFlags", try env.createFunction(getKittyKeyboardFlags, null));
    try exports.setNamedProperty("setupTerminal", try env.createFunction(setupTerminal, null));
    try exports.setNamedProperty("suspendRenderer", try env.createFunction(suspendRenderer, null));
    try exports.setNamedProperty("resumeRenderer", try env.createFunction(resumeRenderer, null));
    try exports.setNamedProperty("queryPixelResolution", try env.createFunction(queryPixelResolution, null));
    try exports.setNamedProperty("writeOut", try env.createFunction(writeOut, null));
    try exports.setNamedProperty("bufferDrawChar", try env.createFunction(bufferDrawChar, null));

    return exports;
}
