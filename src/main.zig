/// Open Responses demo — sends a prompt to an Open Responses-compatible
/// API and prints the response.
///
/// Usage:
///   OPEN_RESPONSES_API_KEY=sk-... zig build run
///
/// Environment:
///   OPEN_RESPONSES_API_KEY  - API key (required)
///   OPEN_RESPONSES_URL      - Base URL (default: https://openrouter.ai/api/v1)
///   OPEN_RESPONSES_MODEL    - Model name (default: openai/gpt-4.1-nano)
///   OPEN_RESPONSES_PROMPT   - Prompt text (default: built-in question)
const std = @import("std");
const Io = std.Io;

const open_responses = @import("open_responses");
const client_mod = open_responses.client;
const types = open_responses.types;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();

    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const api_key = std.c.getenv("OPEN_RESPONSES_API_KEY") orelse {
        const stderr = std.Io.File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writer(io, &buf);
        w.interface.writeAll("error: OPEN_RESPONSES_API_KEY not set\n") catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };

    const url = blk: {
        const env = std.c.getenv("OPEN_RESPONSES_URL");
        break :blk if (env) |e| std.mem.sliceTo(e, 0) else "https://openrouter.ai/api/v1";
    };

    const model = blk: {
        const env = std.c.getenv("OPEN_RESPONSES_MODEL");
        break :blk if (env) |e| std.mem.sliceTo(e, 0) else "openai/gpt-4.1-nano";
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prompt: []const u8 = blk: {
        const env = std.c.getenv("OPEN_RESPONSES_PROMPT");
        break :blk if (env) |e| std.mem.sliceTo(e, 0) else "Explain the Open Responses specification in two sentences.";
    };

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .api_key = std.mem.sliceTo(api_key, 0),
        .model = model,
    });
    defer or_client.deinit();

    // stdout
    const stdout = Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out_w = stdout.writer(io, &out_buf);
    const out = &out_w.interface;

    try out.writeAll("Model: ");
    try out.writeAll(model);
    try out.writeAll("\nPrompt: ");
    try out.writeAll(prompt);
    try out.writeAll("\n\n");
    try out.flush();

    const result = try or_client.create(alloc, .{
        .input = .{ .string = prompt },
    });

    switch (result) {
        .response => |resp| {
            const text = client_mod.getOutputText(resp);
            try out.writeAll(text);
            try out.writeAll("\n");
            try out.flush();
        },
        .api_error => |err| {
            try out.writeAll("API Error (");
            try out.writeAll(err.code);
            try out.writeAll("): ");
            try out.writeAll(err.message);
            try out.writeAll("\n");
            try out.flush();
            std.process.exit(1);
        },
    }
}
