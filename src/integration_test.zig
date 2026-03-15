/// Integration tests for the Open Responses Zig library.
///
/// Uses an in-process Zig HTTP fixture server and raw TCP sockets for
/// requests — no child processes, no curl.  A background thread runs
/// the server's accept+respond while the main thread sends the request.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Io = std.Io;

const types = @import("types.zig");
const sse = @import("sse.zig");
const fixture_server = @import("fixture_server.zig");

// ---------------------------------------------------------------------------
// HTTP client helpers
// ---------------------------------------------------------------------------

const HttpResult = struct {
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *HttpResult) void {
        self.allocator.free(self.body);
    }
};

/// Parse an HTTP response from a reader: status line, headers, body.
fn parseHttpResponse(reader: *Io.Reader, gpa: std.mem.Allocator) !HttpResult {
    // Status line: "HTTP/1.1 200 OK\r\n"
    const status_line = try reader.takeDelimiter('\n') orelse return error.NoResponse;
    var status: u16 = 0;
    {
        const trimmed = std.mem.trimEnd(u8, status_line, &.{ '\r', '\n' });
        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
            if (sp + 4 <= trimmed.len) {
                status = std.fmt.parseInt(u16, trimmed[sp + 1 .. sp + 4], 10) catch 0;
            }
        }
    }

    // Skip headers until blank line
    while (true) {
        const line = try reader.takeDelimiter('\n') orelse break;
        const trimmed = std.mem.trimEnd(u8, line, &.{'\r'});
        if (trimmed.len == 0) break;
    }

    // Read remaining body (server closes connection due to Connection: close)
    const body = try reader.allocRemaining(gpa, Io.Limit.limited(1024 * 1024));
    return .{ .status = status, .body = body, .allocator = gpa };
}

fn httpGet(gpa: std.mem.Allocator, port: u16, path: []const u8) !HttpResult {
    const io = testing.io;
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    const w = &stream_writer.interface;

    try w.writeAll("GET ");
    try w.writeAll(path);
    try w.writeAll(" HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    try w.flush();

    var read_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    return parseHttpResponse(&stream_reader.interface, gpa);
}

fn httpPost(gpa: std.mem.Allocator, port: u16, path: []const u8, scenario: []const u8, payload: []const u8) !HttpResult {
    const io = testing.io;
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [8192]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    const w = &stream_writer.interface;

    var cl_buf: [32]u8 = undefined;
    const cl_str = try std.fmt.bufPrint(&cl_buf, "{d}", .{payload.len});

    try w.writeAll("POST ");
    try w.writeAll(path);
    try w.writeAll(" HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nx-test-scenario: ");
    try w.writeAll(scenario);
    try w.writeAll("\r\nContent-Length: ");
    try w.writeAll(cl_str);
    try w.writeAll("\r\nConnection: close\r\n\r\n");
    if (payload.len > 0) try w.writeAll(payload);
    try w.flush();

    var read_buf: [65536]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    return parseHttpResponse(&stream_reader.interface, gpa);
}

// ---------------------------------------------------------------------------
// Server thread helper
// ---------------------------------------------------------------------------

fn serveOne(server: *fixture_server.FixtureServer, io: Io) void {
    server.serve(io, 1) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "integration" {
    const gpa = testing.allocator;
    const io = testing.io;

    var server = try fixture_server.FixtureServer.start(io);
    defer server.deinit(io);

    try healthCheck(gpa, &server);
    try nonStreamingText(gpa, &server);
    try nonStreamingFunctionCall(gpa, &server);
    try streamingText(gpa, &server);
    try streamingFunctionCallArguments(gpa, &server);
    try toolLoopMultiTurn(gpa, &server);
    try createResponseBodySerialization(gpa, &server);
}

fn healthCheck(gpa: std.mem.Allocator, server: *fixture_server.FixtureServer) !void {
    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
    var r = try httpGet(gpa, server.port, "/health");
    defer r.deinit();
    thread.join();

    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "\"ok\"") != null);
}

fn nonStreamingText(gpa: std.mem.Allocator, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
    var r = try httpPost(gpa, server.port, "/responses", "text",
        \\{"model":"test-model","input":"Hello"}
    );
    defer r.deinit();
    thread.join();

    try testing.expectEqual(@as(u16, 200), r.status);

    const value = try json.parseFromSliceLeaky(json.Value, alloc, r.body, .{});
    const resp = try json.parseFromValueLeaky(types.ResponseResource, alloc, value, .{ .ignore_unknown_fields = true });

    try testing.expectEqual(types.ResponseStatus.completed, resp.status);
    try testing.expect(resp.output.len == 1);

    switch (resp.output[0]) {
        .message => |msg| {
            try testing.expectEqual(types.MessageRole.assistant, msg.role);
            switch (msg.content[0]) {
                .output_text => |t| try testing.expectEqualStrings("Hello, world!", t.text),
                else => return error.UnexpectedContent,
            }
        },
        else => return error.UnexpectedOutput,
    }
}

fn nonStreamingFunctionCall(gpa: std.mem.Allocator, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
    var r = try httpPost(gpa, server.port, "/responses", "function-call",
        \\{"model":"test-model","input":"Weather?"}
    );
    defer r.deinit();
    thread.join();

    const value = try json.parseFromSliceLeaky(json.Value, alloc, r.body, .{});
    const resp = try json.parseFromValueLeaky(types.ResponseResource, alloc, value, .{ .ignore_unknown_fields = true });

    switch (resp.output[0]) {
        .function_call => |fc| {
            try testing.expectEqualStrings("get_weather", fc.name);
            try testing.expectEqualStrings("call_abc123", fc.call_id);
        },
        else => return error.UnexpectedOutput,
    }
}

fn streamingText(gpa: std.mem.Allocator, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
    var r = try httpPost(gpa, server.port, "/responses", "text",
        \\{"model":"test-model","input":"Hello","stream":true}
    );
    defer r.deinit();
    thread.join();

    var reader: Io.Reader = .fixed(r.body);
    var parser = sse.SseParser.init(alloc, &reader);

    var text_buf = std.ArrayList(u8).empty;
    var got_completed = false;

    while (try parser.nextEvent()) |event| {
        switch (event) {
            .@"response.output_text.delta" => |e| {
                try text_buf.appendSlice(alloc, e.delta);
            },
            .@"response.completed" => |e| {
                got_completed = true;
                try testing.expectEqual(types.ResponseStatus.completed, e.response.status);
            },
            else => {},
        }
    }

    try testing.expect(got_completed);
    try testing.expectEqualStrings("Hello, world!", text_buf.items);
}

fn streamingFunctionCallArguments(gpa: std.mem.Allocator, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
    var r = try httpPost(gpa, server.port, "/responses", "function-call",
        \\{"model":"test-model","input":"Weather?","stream":true}
    );
    defer r.deinit();
    thread.join();

    var reader: Io.Reader = .fixed(r.body);
    var parser = sse.SseParser.init(alloc, &reader);

    var args_buf = std.ArrayList(u8).empty;
    var got_done = false;

    while (try parser.nextEvent()) |event| {
        switch (event) {
            .@"response.function_call_arguments.delta" => |e| {
                try args_buf.appendSlice(alloc, e.delta);
            },
            .@"response.function_call_arguments.done" => {
                got_done = true;
            },
            else => {},
        }
    }

    try testing.expect(got_done);
    try testing.expectEqualStrings("{\"city\":\"San Francisco\"}", args_buf.items);
}

fn toolLoopMultiTurn(gpa: std.mem.Allocator, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Turn 1: expect function call
    {
        const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
        var r = try httpPost(gpa, server.port, "/responses", "tool-loop",
            \\{"model":"test-model","input":[{"type":"message","role":"user","content":"Weather?"}]}
        );
        defer r.deinit();
        thread.join();

        const val = try json.parseFromSliceLeaky(json.Value, alloc, r.body, .{});
        const resp = try json.parseFromValueLeaky(types.ResponseResource, alloc, val, .{ .ignore_unknown_fields = true });

        switch (resp.output[0]) {
            .function_call => |fc| try testing.expectEqualStrings("get_weather", fc.name),
            else => return error.UnexpectedOutput,
        }
    }

    // Turn 2: send tool result, expect text
    {
        const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
        var r = try httpPost(gpa, server.port, "/responses", "tool-loop",
            \\{"model":"test-model","input":[{"type":"message","role":"user","content":"Weather?"},{"type":"function_call_output","call_id":"call_loop_1","output":"22C"}]}
        );
        defer r.deinit();
        thread.join();

        const val = try json.parseFromSliceLeaky(json.Value, alloc, r.body, .{});
        const resp = try json.parseFromValueLeaky(types.ResponseResource, alloc, val, .{ .ignore_unknown_fields = true });
        try testing.expectEqual(types.ResponseStatus.completed, resp.status);

        switch (resp.output[0]) {
            .message => {},
            else => return error.UnexpectedOutput,
        }
    }
}

fn createResponseBodySerialization(gpa: std.mem.Allocator, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = types.CreateResponseBody{
        .model = "test-model",
        .input = .{ .string = "Hello" },
        .temperature = 0.7,
    };

    var ser_buf: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&ser_buf);
    var jws: json.Stringify = .{ .writer = &writer, .options = .{ .emit_null_optional_fields = false } };
    try jws.write(req);
    const payload = writer.buffered();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, testing.io });
    var r = try httpPost(gpa, server.port, "/responses", "text", payload);
    defer r.deinit();
    thread.join();

    try testing.expectEqual(@as(u16, 200), r.status);

    const value = try json.parseFromSliceLeaky(json.Value, alloc, r.body, .{});
    const resp = try json.parseFromValueLeaky(types.ResponseResource, alloc, value, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(types.ResponseStatus.completed, resp.status);
}
