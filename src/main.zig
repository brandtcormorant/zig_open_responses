/// Open Responses CLI — chat with an Open Responses-compatible API.
///
/// Usage:
///   open-responses [options] [prompt...]
///
/// If a prompt is given on the command line, sends it and prints the
/// streaming response (single-shot mode).
///
/// If no prompt is given, enters interactive chat mode: reads lines
/// from stdin, streams responses, and accumulates multi-turn context.
///
/// Configuration:
///   ~/.config/openresponses/config.json - default model and url
///   OPEN_RESPONSES_API_KEY env var      - API key
///
/// Priority: CLI flags > environment variables > config file > defaults
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cmd = @import("zig_command");
const open_responses = @import("open_responses");
const client_mod = open_responses.client;
const types = open_responses.types;

const default_url = "https://openrouter.ai/api/v1";
const default_model = "anthropic/claude-opus-4.6";

const cli_schema = cmd.Command{
    .name = "open-responses",
    .description = "Chat with an Open Responses-compatible API. Streams responses in real time.\n\nWith a prompt argument: single-shot mode.\nWithout: interactive chat mode (type messages, Ctrl-D to quit).",
    .args = &.{
        .{ .name = "prompt", .required = false, .variadic = true, .description = "Prompt text (single-shot mode)" },
    },
    .flags = &.{
        .{ .name = "url", .short = 'u', .kind = .string, .description = "API base URL" },
        .{ .name = "model", .short = 'm', .kind = .string, .description = "Model name" },
        .{ .name = "api-key", .short = 'k', .kind = .string, .description = "API key" },
        .{ .name = "system", .short = 's', .kind = .string, .description = "System prompt / instructions" },
    },
    .examples = &.{
        "open-responses \"Explain quantum computing\"",
        "open-responses -m google/gemma-3n-e2b-it:free \"Hello\"",
        "open-responses  # enters interactive chat mode",
    },
};

const FileConfig = struct {
    model: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const raw_argv = try init.minimal.args.toSlice(arena);
    const skip: usize = if (raw_argv.len > 0) 1 else 0;
    const argv = try arena.alloc([]const u8, raw_argv.len - skip);
    for (raw_argv[skip..], argv) |src, *dst| dst.* = src;

    var parsed = cmd.parse(arena, argv, &cli_schema) catch |err| {
        printErr(io, switch (err) {
            error.MissingFlagValue => "error: missing flag value\n",
            error.InvalidNumber => "error: invalid number\n",
            error.InvalidFlag => "error: invalid flag\n",
            error.OutOfMemory => "error: out of memory\n",
        });
        std.process.exit(1);
    };
    defer parsed.deinit();

    const stdout_file = Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out_w = stdout_file.writerStreaming(io, &out_buf);
    const out = &out_w.interface;

    if (parsed.help_requested) {
        const help = try cmd.formatHelp(arena, parsed.command, parsed.parents.items);
        try out.writeAll(help);
        try out.flush();
        return;
    }

    const config = loadConfig(arena, io);

    const api_key = parsed.getString("api-key") orelse
        getEnv("OPEN_RESPONSES_API_KEY") orelse {
        printErr(io, "error: API key required (--api-key or OPEN_RESPONSES_API_KEY)\n");
        std.process.exit(1);
    };

    const url = parsed.getString("url") orelse
        getEnv("OPEN_RESPONSES_URL") orelse
        config.url orelse default_url;

    const model = parsed.getString("model") orelse getEnv("OPEN_RESPONSES_MODEL") orelse config.model orelse default_model;

    const system_prompt = parsed.getString("system") orelse getEnv("OPEN_RESPONSES_SYSTEM") orelse null;

    var or_client = client_mod.OpenResponses.init(allocator, io, .{
        .url = url,
        .api_key = api_key,
        .model = model,
    });
    defer or_client.deinit();

    // Single-shot mode: prompt on command line or env var
    const cli_prompt: ?[]const u8 = if (parsed.args.items.len > 0)
        try std.mem.join(arena, " ", parsed.args.items)
    else
        getEnv("OPEN_RESPONSES_PROMPT");

    if (cli_prompt) |prompt| {
        try out.writeAll("Model: ");
        try out.writeAll(model);
        try out.writeAll("\n\n");
        try out.flush();
        try streamOneShot(&or_client, arena, prompt, system_prompt, out);
        return;
    }

    // Interactive chat mode
    try out.writeAll("Model: ");
    try out.writeAll(model);
    try out.writeAll("\nType a message. /quit to exit, /reset to clear context.\n\n");
    try out.flush();

    try chatLoop(&or_client, allocator, io, system_prompt, out);
}

fn streamOneShot(
    or_client: *client_mod.OpenResponses,
    arena: Allocator,
    prompt: []const u8,
    system_prompt: ?[]const u8,
    out: *Io.Writer,
) !void {
    const stream_result = try or_client.stream(arena, .{
        .input = .{ .string = prompt },
        .instructions = system_prompt,
    });

    switch (stream_result) {
        .api_error => |err| {
            try writeApiError(out, err);
            std.process.exit(1);
        },
        .stream => |s| {
            defer s.deinit();
            try drainStream(s, out);
            try out.writeAll("\n");
            try out.flush();
        },
    }
}

fn chatLoop(
    or_client: *client_mod.OpenResponses,
    allocator: Allocator,
    io: Io,
    system_prompt: ?[]const u8,
    out: *Io.Writer,
) !void {
    var input_list: std.ArrayList(types.ItemParam) = .empty;
    const stdin_file = Io.File.stdin();
    var stdin_buf: [8192]u8 = undefined;
    var stdin_reader = stdin_file.readerStreaming(io, &stdin_buf);
    const reader = &stdin_reader.interface;

    while (true) {
        try out.writeAll("> ");
        try out.flush();

        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try out.writeAll("(input too long)\n");
                try out.flush();
                continue;
            },
            else => return err,
        } orelse break;

        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/exit")) break;

        if (std.mem.eql(u8, trimmed, "/reset")) {
            input_list.clearRetainingCapacity();
            try out.writeAll("(context cleared)\n\n");
            try out.flush();
            continue;
        }

        const user_text = try allocator.dupe(u8, trimmed);

        try input_list.append(allocator, .{
            .message = .{ .user = .{ .role = .user, .content = .{ .string = user_text } } },
        });

        const stream_result = try or_client.stream(allocator, .{
            .input = .{ .items = input_list.items },
            .instructions = system_prompt,
        });

        switch (stream_result) {
            .api_error => |err| {
                try writeApiError(out, err);
                continue;
            },
            .stream => |s| {
                defer s.deinit();

                var completed_response: ?types.ResponseResource = null;

                while (try s.next()) |event| {
                    switch (event) {
                        .@"response.output_text.delta" => |e| {
                            try out.writeAll(e.delta);
                            try out.flush();
                        },
                        .@"response.completed" => |e| {
                            completed_response = e.response;
                        },
                        .@"response.failed" => |e| {
                            if (e.response.@"error") |err| {
                                try out.writeAll("\nError: ");
                                try out.writeAll(err.message);
                            } else {
                                try out.writeAll("\nResponse failed");
                            }
                            try out.writeAll("\n");
                            try out.flush();
                            break;
                        },
                        .@"error" => |e| {
                            try out.writeAll("\nStream error: ");
                            try out.writeAll(e.@"error".message);
                            try out.writeAll("\n");
                            try out.flush();
                            break;
                        },
                        else => {},
                    }
                }

                try out.writeAll("\n\n");
                try out.flush();

                if (completed_response) |resp| {
                    const output_params = client_mod.itemFieldsToParams(allocator, resp.output) catch continue;
                    for (output_params) |p| {
                        input_list.append(allocator, p) catch continue;
                    }
                }
            },
        }
    }

    try out.writeAll("\n");
    try out.flush();
}

fn drainStream(s: *client_mod.OpenResponses.Stream, out: *Io.Writer) !void {
    while (try s.next()) |event| {
        switch (event) {
            .@"response.output_text.delta" => |e| {
                try out.writeAll(e.delta);
                try out.flush();
            },
            .@"response.completed" => {},
            .@"response.failed" => |e| {
                if (e.response.@"error") |err| {
                    try out.writeAll("\nError: ");
                    try out.writeAll(err.message);
                } else {
                    try out.writeAll("\nResponse failed");
                }
                try out.writeAll("\n");
                try out.flush();
                std.process.exit(1);
            },
            .@"error" => |e| {
                try out.writeAll("\nStream error: ");
                try out.writeAll(e.@"error".message);
                try out.writeAll("\n");
                try out.flush();
                std.process.exit(1);
            },
            else => {},
        }
    }
}

fn writeApiError(out: *Io.Writer, err: client_mod.OpenResponsesError) !void {
    try out.writeAll("API Error (");
    try out.writeAll(err.code);
    try out.writeAll("): ");
    try out.writeAll(err.message);
    try out.writeAll("\n");
    try out.flush();
}

fn loadConfig(allocator: Allocator, io: Io) FileConfig {
    const home = std.c.getenv("HOME") orelse return .{};

    const path = std.fmt.allocPrint(allocator, "{s}/.config/openresponses/config.json", .{
        std.mem.sliceTo(home, 0),
    }) catch return .{};

    const cwd: Io.Dir = .cwd();
    const content = cwd.readFileAlloc(io, path, allocator, .unlimited) catch return .{};

    return std.json.parseFromSliceLeaky(FileConfig, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch .{};
}

fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(val, 0);
}

fn printErr(io: Io, msg: []const u8) void {
    const stderr = Io.File.stderr();
    var buf: [1024]u8 = undefined;
    var w = stderr.writerStreaming(io, &buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}
