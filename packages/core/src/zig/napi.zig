const std = @import("std");
const napi = @import("napi");
const lib = @import("lib");

const CliRenderer = lib.CliRenderer;
const OptimizedBuffer = lib.OptimizedBuffer;
const RGBA = lib.RGBA;

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
    try exports.setNamedProperty("resizeRenderer", try env.createFunction(resizeRenderer, null));
    try exports.setNamedProperty("setCursorPosition", try env.createFunction(setCursorPosition, null));
    try exports.setNamedProperty("setCursorStyle", try env.createFunction(setCursorStyle, null));
    try exports.setNamedProperty("setCursorColor", try env.createFunction(setCursorColor, null));
    try exports.setNamedProperty("getCursorState", try env.createFunction(getCursorState, null));
    try exports.setNamedProperty("setDebugOverlay", try env.createFunction(setDebugOverlay, null));
    try exports.setNamedProperty("clearTerminal", try env.createFunction(clearTerminal, null));
    try exports.setNamedProperty("setTerminalTitle", try env.createFunction(setTerminalTitle, null));
    try exports.setNamedProperty("setupTerminal", try env.createFunction(setupTerminal, null));
    try exports.setNamedProperty("suspendRenderer", try env.createFunction(suspendRenderer, null));
    try exports.setNamedProperty("resumeRenderer", try env.createFunction(resumeRenderer, null));
    try exports.setNamedProperty("queryPixelResolution", try env.createFunction(queryPixelResolution, null));
    try exports.setNamedProperty("writeOut", try env.createFunction(writeOut, null));
    try exports.setNamedProperty("bufferDrawChar", try env.createFunction(bufferDrawChar, null));

    return exports;
}
