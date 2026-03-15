/// Integration tests for the OpenResponses client.
///
/// Tests create() and stream() against the in-process fixture server
/// using std.http.Client (the real HTTP stack, no raw TCP).
const std = @import("std");
const testing = std.testing;
const http = std.http;
const Io = std.Io;

const types = @import("types.zig");
const client_mod = @import("client.zig");
const fixture_server = @import("fixture_server.zig");

const OpenResponses = client_mod.OpenResponses;

// ---------------------------------------------------------------------------
// Server thread helper
// ---------------------------------------------------------------------------

fn serveN(server: *fixture_server.FixtureServer, io: Io, n: usize) void {
    server.serve(io, n) catch {};
}

fn serveOne(server: *fixture_server.FixtureServer, io: Io) void {
    serveN(server, io, 1);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "client integration" {
    const gpa = testing.allocator;
    const io = testing.io;

    var server = try fixture_server.FixtureServer.start(io);
    defer server.deinit(io);

    try clientCreate(gpa, io, &server);
    try clientStream(gpa, io, &server);
    try clientCreateError(gpa, io, &server);
    try clientCreateFailed(gpa, io, &server);
    try clientStreamError(gpa, io, &server);
    try clientToolLoop(gpa, io, &server);
    try clientToolLoopMaxTurns(gpa, io, &server);
    try clientStreamToolLoop(gpa, io, &server);
    try clientStreamToolLoopError(gpa, io, &server);
    try clientDoneToolLoop(gpa, io, &server);
    try clientStreamToolLoopMultiTurn(gpa, io, &server);
    try clientStreamText(gpa, io, &server);
    try clientStreamTextError(gpa, io, &server);
}

fn clientCreate(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var or_client = OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, io });

    const result = try or_client.create(alloc, .{
        .input = .{ .string = "Hello" },
    });
    thread.join();

    // Should be a successful response
    switch (result) {
        .response => |resp| {
            try testing.expectEqualStrings("resp_1", resp.id);
            try testing.expectEqual(types.ResponseStatus.completed, resp.status);
            try testing.expect(resp.output.len == 1);
            const text = client_mod.getOutputText(resp);
            try testing.expectEqualStrings("Hello, world!", text);
        },
        .api_error => return error.UnexpectedApiError,
    }
}

fn clientStream(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var or_client = OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, io });

    const result = try or_client.stream(alloc, .{
        .input = .{ .string = "Hello" },
    });
    thread.join();

    switch (result) {
        .stream => |s| {
            defer s.deinit();

            var text_buf = std.ArrayList(u8).empty;
            var got_completed = false;

            while (try s.next()) |event| {
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
        },
        .api_error => return error.UnexpectedApiError,
    }
}

fn clientCreateError(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var or_client = OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "error" },
        },
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, io });

    const result = try or_client.create(alloc, .{
        .input = .{ .string = "Hello" },
    });
    thread.join();

    switch (result) {
        .api_error => |err| {
            try testing.expectEqual(@as(u16, 400), err.status);
            try testing.expectEqualStrings("invalid_request", err.code);
            try testing.expect(std.mem.indexOf(u8, err.message, "missing required field") != null);
        },
        .response => return error.ExpectedApiError,
    }
}

fn clientCreateFailed(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    // The "failed" scenario returns HTTP 200 with status: "failed" in the body
    var or_client = OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "failed" },
        },
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, io });

    const result = try or_client.create(alloc, .{
        .input = .{ .string = "Hello" },
    });
    thread.join();

    // HTTP 200, but the response has status: "failed"
    switch (result) {
        .response => |resp| {
            try testing.expect(client_mod.isError(resp));
            try testing.expectEqual(types.ResponseStatus.failed, resp.status);
            try testing.expectEqualStrings("server_error", resp.@"error".?.code);
            try testing.expectEqualStrings("Internal model error", resp.@"error".?.message);
        },
        .api_error => return error.UnexpectedApiError,
    }
}

fn clientStreamError(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    // Use the "error" scenario which returns HTTP 400 — stream() should
    // detect non-2xx and return api_error.
    var or_client = OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "error" },
        },
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, io });

    const result = try or_client.stream(alloc, .{
        .input = .{ .string = "Hello" },
    });
    thread.join();

    switch (result) {
        .api_error => |err| {
            try testing.expectEqual(@as(u16, 400), err.status);
            try testing.expectEqualStrings("invalid_request", err.code);
        },
        .stream => |s| {
            s.deinit();
            return error.ExpectedApiError;
        },
    }
}

// ---------------------------------------------------------------------------
// Tool loop tests
// ---------------------------------------------------------------------------

const WeatherHandler = struct {
    fn callback(_: *anyopaque, _: []const u8, _: []const u8) anyerror!client_mod.ToolResult {
        return .{ .output = "22C and sunny" };
    }
};

fn clientToolLoop(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var dummy_ctx: u8 = 0;
    const handlers = [_]client_mod.ToolHandler{
        .{ .name = "get_weather", .callback = &WeatherHandler.callback, .ctx = @ptrCast(&dummy_ctx) },
    };

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "tool-loop" },
        },
    });
    defer or_client.deinit();

    // Tool loop needs 2 requests: turn 1 (function_call), turn 2 (text)
    const thread = try std.Thread.spawn(.{}, serveN, .{ server, io, 2 });

    const result = try client_mod.toolLoop(
        &or_client,
        alloc,
        .{ .input = .{ .string = "Weather?" } },
        &handlers,
        .{},
    );
    thread.join();

    switch (result) {
        .response => |r| {
            try testing.expectEqual(types.ResponseStatus.completed, r.response.status);
            const text = client_mod.getOutputText(r.response);
            try testing.expect(text.len > 0);
        },
        .api_error => return error.UnexpectedApiError,
        .max_turns_exceeded => return error.UnexpectedMaxTurns,
    }
}

fn clientToolLoopMaxTurns(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var dummy_ctx: u8 = 0;
    const handlers = [_]client_mod.ToolHandler{
        .{ .name = "get_weather", .callback = &WeatherHandler.callback, .ctx = @ptrCast(&dummy_ctx) },
    };

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            // Use "function-call" scenario which always returns a function_call
            // (never text) — so the loop will never terminate naturally.
            .{ .name = "x-test-scenario", .value = "function-call" },
        },
    });
    defer or_client.deinit();

    // Serve exactly 1 request (max_turns = 1, so 1 create call)
    const thread = try std.Thread.spawn(.{}, serveN, .{ server, io, 1 });

    const result = try client_mod.toolLoop(
        &or_client,
        alloc,
        .{ .input = .{ .string = "Weather?" } },
        &handlers,
        .{ .max_turns = 1 },
    );
    thread.join();

    switch (result) {
        .max_turns_exceeded => {}, // expected
        else => return error.ExpectedMaxTurns,
    }
}

fn clientStreamToolLoop(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var dummy_ctx: u8 = 0;
    const handlers = [_]client_mod.ToolHandler{
        .{ .name = "get_weather", .callback = &WeatherHandler.callback, .ctx = @ptrCast(&dummy_ctx) },
    };

    const EventCounter = struct {
        count: u32 = 0,

        fn onEvent(ctx: *anyopaque, _: types.StreamingEvent, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
    };
    var counter = EventCounter{};

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            // Streaming text scenario — single turn, no tool calls
            .{ .name = "x-test-scenario", .value = "text" },
        },
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveN, .{ server, io, 1 });

    const result = try client_mod.streamToolLoop(
        &or_client,
        alloc,
        .{ .input = .{ .string = "Hello" } },
        &handlers,
        &EventCounter.onEvent,
        @ptrCast(&counter),
        .{},
    );
    thread.join();

    switch (result) {
        .response => |r| {
            try testing.expectEqual(types.ResponseStatus.completed, r.response.status);
            try testing.expect(counter.count > 0); // events were forwarded
        },
        else => return error.UnexpectedResult,
    }
}

fn clientStreamToolLoopError(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    const NullCounter = struct {
        fn onEvent(_: *anyopaque, _: types.StreamingEvent, _: u32) void {}
    };
    var dummy_ctx: u8 = 0;

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "stream-error" },
        },
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveN, .{ server, io, 1 });

    const result = try client_mod.streamToolLoop(
        &or_client,
        alloc,
        .{ .input = .{ .string = "Hello" } },
        &.{},
        &NullCounter.onEvent,
        @ptrCast(&dummy_ctx),
        .{},
    );
    thread.join();

    switch (result) {
        .stream_error => |err| {
            try testing.expectEqualStrings("rate_limit_exceeded", err.code.?);
        },
        else => return error.ExpectedStreamError,
    }
}

fn clientDoneToolLoop(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    const SideEffectHandler = struct {
        called: bool = false,

        fn callback(ctx: *anyopaque, _: []const u8, _: []const u8) anyerror!client_mod.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            return .{ .output = "22C" };
        }
    };
    var handler_state = SideEffectHandler{};

    const handlers = [_]client_mod.ToolHandler{
        .{ .name = "get_weather", .callback = &SideEffectHandler.callback, .ctx = @ptrCast(&handler_state) },
    };

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "done-tool" },
        },
    });
    defer or_client.deinit();

    // Only 1 request — done_tool_name causes immediate return
    const thread = try std.Thread.spawn(.{}, serveN, .{ server, io, 1 });

    const result = try client_mod.toolLoop(
        &or_client,
        alloc,
        .{ .input = .{ .string = "Weather?" } },
        &handlers,
        .{ .done_tool_name = "finish" },
    );
    thread.join();

    switch (result) {
        .response => |r| {
            try testing.expectEqual(types.ResponseStatus.completed, r.response.status);
            // The non-done tool (get_weather) should have been executed
            try testing.expect(handler_state.called);
            try testing.expect(r.response.output.len == 2);
            // done_tool_results should be populated with the weather handler output
            try testing.expect(r.done_tool_results != null);
            try testing.expect(r.done_tool_results.?.len == 1);
        },
        .api_error => return error.UnexpectedApiError,
        .max_turns_exceeded => return error.UnexpectedMaxTurns,
    }
}

fn clientStreamToolLoopMultiTurn(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var dummy_ctx: u8 = 0;
    const handlers = [_]client_mod.ToolHandler{
        .{ .name = "get_weather", .callback = &WeatherHandler.callback, .ctx = @ptrCast(&dummy_ctx) },
    };

    const TurnCounter = struct {
        max_turn: u32 = 0,

        fn onEvent(ctx: *anyopaque, _: types.StreamingEvent, turn: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (turn > self.max_turn) self.max_turn = turn;
        }
    };
    var counter = TurnCounter{};

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "tool-loop" },
        },
    });
    defer or_client.deinit();

    // 2 requests: turn 1 (function_call SSE), turn 2 (text SSE)
    const thread = try std.Thread.spawn(.{}, serveN, .{ server, io, 2 });

    const result = try client_mod.streamToolLoop(
        &or_client,
        alloc,
        .{ .input = .{ .string = "Weather?" } },
        &handlers,
        &TurnCounter.onEvent,
        @ptrCast(&counter),
        .{},
    );
    thread.join();

    switch (result) {
        .response => |r| {
            try testing.expectEqual(types.ResponseStatus.completed, r.response.status);
            const text = client_mod.getOutputText(r.response);
            try testing.expectEqualStrings("Hello, world!", text);
            // Should have gone through 2 turns
            try testing.expectEqual(@as(u32, 2), counter.max_turn);
        },
        else => return error.UnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// streamText tests
// ---------------------------------------------------------------------------

fn clientStreamText(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, io });

    const result = try or_client.streamText(alloc, .{
        .input = .{ .string = "Hello" },
    });
    thread.join();

    switch (result) {
        .result => |r| {
            try testing.expectEqualStrings("Hello, world!", r.text);
            try testing.expectEqual(types.ResponseStatus.completed, r.response.status);
            try testing.expectEqualStrings("resp_1", r.response.id);
        },
        else => return error.UnexpectedResult,
    }
}

fn clientStreamTextError(gpa: std.mem.Allocator, io: Io, server: *fixture_server.FixtureServer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{server.port});

    var or_client = client_mod.OpenResponses.init(gpa, io, .{
        .url = url,
        .model = "test-model",
        .extra_headers = &.{
            .{ .name = "x-test-scenario", .value = "stream-error" },
        },
    });
    defer or_client.deinit();

    const thread = try std.Thread.spawn(.{}, serveOne, .{ server, io });

    const result = try or_client.streamText(alloc, .{
        .input = .{ .string = "Hello" },
    });
    thread.join();

    switch (result) {
        .stream_error => |err| {
            try testing.expectEqualStrings("rate_limit_exceeded", err.code.?);
        },
        else => return error.ExpectedStreamError,
    }
}
