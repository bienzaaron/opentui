const std = @import("std");
const napi = @import("napi");
const lib = @import("lib");

const CliRenderer = lib.CliRenderer;
const OptimizedBuffer = lib.OptimizedBuffer;
const RGBA = lib.RGBA;

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
    } else {
        return try env.getNull();
    }
}

fn extractFloat32Array(val: napi.Value, comptime size: usize) ![size]f32 {
    // Extract individual float values from the Float32Array
    var result: [size]f32 = undefined;
    for (0..size) |i| {
        const element = try val.getElement(@intCast(i));
        const value_f64 = try element.getValue(f64);
        result[i] = @floatCast(value_f64);
    }
    return result;
}

fn f32PtrToRGBA(ptr: [*]const f32) RGBA {
    return .{ ptr[0], ptr[1], ptr[2], ptr[3] };
}

fn createRenderer(env: napi.Env, width_val: napi.Value, height_val: napi.Value, testing_val: napi.Value, remote_val: napi.Value) !napi.Value {
    const width = try width_val.getValue(u32);
    const height = try height_val.getValue(u32);
    const testing = try testing_val.getValue(bool);
    const remote = try remote_val.getValue(bool);
    return optionalPtrToValue(env, lib.createRenderer(width, height, testing, remote));
}

fn destroyRenderer(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    lib.destroyRenderer(renderer_ptr);
    return try env.getNull();
}

fn render(env: napi.Env, ptr_val: napi.Value, force_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    const force = try force_val.getValue(bool);
    lib.render(renderer_ptr, force);
    return try env.getNull();
}

fn getNextBuffer(env: napi.Env, ptr_val: napi.Value) !napi.Value {
    const renderer_ptr = try valueToPtr(*CliRenderer, ptr_val);
    return try ptrToValue(env, lib.getNextBuffer(renderer_ptr));
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

fn bufferDrawChar(env: napi.Env, buffer_ptr_val: napi.Value, char_val: napi.Value, x_val: napi.Value, y_val: napi.Value, fg_val: napi.Value, bg_val: napi.Value, attributes_val: napi.Value) !napi.Value {
    const buffer_ptr = try valueToPtr(*OptimizedBuffer, buffer_ptr_val);
    const char = try char_val.getValue(u32);
    const x = try x_val.getValue(u32);
    const y = try y_val.getValue(u32);

    // Extract Float32Arrays and convert to RGBA
    const fg_f32 = try extractFloat32Array(fg_val, 4);
    const bg_f32 = try extractFloat32Array(bg_val, 4);
    const fg = f32PtrToRGBA(&fg_f32);
    const bg = f32PtrToRGBA(&bg_f32);

    const attributes = try attributes_val.getValue(u32);

    lib.bufferDrawChar(buffer_ptr, char, x, y, &fg, &bg, attributes);
    return try env.getNull();
}

fn init(env: napi.Env, exports: napi.Value) !napi.Value {
    // create
    try exports.setNamedProperty("createRenderer", try env.createFunction(createRenderer, null));
    try exports.setNamedProperty("destroyRenderer", try env.createFunction(destroyRenderer, null));
    try exports.setNamedProperty("getNextBuffer", try env.createFunction(getNextBuffer, null));
    try exports.setNamedProperty("render", try env.createFunction(render, null));
    try exports.setNamedProperty("getBufferWidth", try env.createFunction(getBufferWidth, null));
    try exports.setNamedProperty("getBufferHeight", try env.createFunction(getBufferHeight, null));
    try exports.setNamedProperty("bufferDrawChar", try env.createFunction(bufferDrawChar, null));
    return exports;
}
