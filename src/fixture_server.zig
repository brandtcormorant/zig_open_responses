/// Minimal HTTP fixture server for integration tests.
///
/// Serves canned Open Responses payloads over HTTP/1.1 using
/// `std.http.Server` and `std.Io.net`.  No TLS, no external
/// dependencies — compiles in ~3 s.
const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = Io.net;

const base_response_prefix =
    \\{"id":"resp_1","object":"response","created_at":1700000000,"completed_at":1700000005,"status":"completed","model":"test-model","output":
;

const base_response_suffix =
    \\,"error":null,"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"incomplete_details":null,"tools":[],"tool_choice":"auto","parallel_tool_calls":true,"temperature":1,"top_p":1,"metadata":{}}
;

const text_output =
    \\[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hello, world!","annotations":[]}]}]
;

const function_call_output =
    \\[{"type":"function_call","id":"fc_1","call_id":"call_abc123","name":"get_weather","arguments":"{\"city\":\"San Francisco\"}","status":"completed"}]
;

const tool_loop_fc_output =
    \\[{"type":"function_call","id":"fc_1","call_id":"call_loop_1","name":"get_weather","arguments":"{\"city\":\"San Francisco\"}","status":"completed"}]
;

const tool_loop_text_output =
    \\[{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"The weather in San Francisco is 22°C and sunny.","annotations":[]}]}]
;

const done_tool_output =
    \\[{"type":"function_call","id":"fc_1","call_id":"call_done_1","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"},{"type":"function_call","id":"fc_2","call_id":"call_done_2","name":"finish","arguments":"{}","status":"completed"}]
;

// Error/failed payloads
const error_response_body =
    \\{"error":{"code":"invalid_request","message":"Bad request: missing required field 'model'"}}
;

const failed_response_prefix =
    \\{"id":"resp_err","object":"response","created_at":1700000000,"completed_at":null,"status":"failed","model":"test-model","output":[]
;

const failed_response_suffix =
    \\,"error":{"code":"server_error","message":"Internal model error"},"usage":null,"incomplete_details":null,"tools":[],"tool_choice":"auto","parallel_tool_calls":true,"temperature":1,"top_p":1,"metadata":{}}
;

// ---------------------------------------------------------------------------
// SSE streaming payloads
// ---------------------------------------------------------------------------

const partial_response = "{\"id\":\"resp_1\",\"object\":\"response\",\"created_at\":1700000000,\"status\":\"in_progress\",\"model\":\"test-model\",\"output\":[]}";

const text_sse =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":" ++ partial_response ++ "}\n\n" ++
    "event: response.in_progress\n" ++
    "data: {\"type\":\"response.in_progress\",\"sequence_number\":1,\"response\":" ++ partial_response ++ "}\n\n" ++
    "event: response.output_item.added\n" ++
    "data: {\"type\":\"response.output_item.added\",\"sequence_number\":2,\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"status\":\"in_progress\",\"role\":\"assistant\",\"content\":[]}}\n\n" ++
    "event: response.content_part.added\n" ++
    "data: {\"type\":\"response.content_part.added\",\"sequence_number\":3,\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\",\"annotations\":[]}}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":4,\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":5,\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\", \"}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":6,\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"world!\"}\n\n" ++
    "event: response.output_text.done\n" ++
    "data: {\"type\":\"response.output_text.done\",\"sequence_number\":7,\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"text\":\"Hello, world!\"}\n\n" ++
    "event: response.content_part.done\n" ++
    "data: {\"type\":\"response.content_part.done\",\"sequence_number\":8,\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"Hello, world!\",\"annotations\":[]}}\n\n" ++
    "event: response.output_item.done\n" ++
    "data: {\"type\":\"response.output_item.done\",\"sequence_number\":9,\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello, world!\",\"annotations\":[]}]}}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"sequence_number\":10,\"response\":" ++ base_response_prefix ++ text_output ++ base_response_suffix ++ "}\n\n" ++
    "data: [DONE]\n\n";

const function_call_sse =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":" ++ partial_response ++ "}\n\n" ++
    "event: response.in_progress\n" ++
    "data: {\"type\":\"response.in_progress\",\"sequence_number\":1,\"response\":" ++ partial_response ++ "}\n\n" ++
    "event: response.output_item.added\n" ++
    "data: {\"type\":\"response.output_item.added\",\"sequence_number\":2,\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc123\",\"name\":\"get_weather\",\"arguments\":\"\",\"status\":\"in_progress\"}}\n\n" ++
    "event: response.function_call_arguments.delta\n" ++
    "data: {\"type\":\"response.function_call_arguments.delta\",\"sequence_number\":3,\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"{\\\"city\\\":\"}\n\n" ++
    "event: response.function_call_arguments.delta\n" ++
    "data: {\"type\":\"response.function_call_arguments.delta\",\"sequence_number\":4,\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"\\\"San Francisco\\\"}\"}\n\n" ++
    "event: response.function_call_arguments.done\n" ++
    "data: {\"type\":\"response.function_call_arguments.done\",\"sequence_number\":5,\"item_id\":\"fc_1\",\"output_index\":0,\"arguments\":\"{\\\"city\\\":\\\"San Francisco\\\"}\"}\n\n" ++
    "event: response.output_item.done\n" ++
    "data: {\"type\":\"response.output_item.done\",\"sequence_number\":6,\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc123\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"San Francisco\\\"}\",\"status\":\"completed\"}}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"sequence_number\":7,\"response\":" ++ base_response_prefix ++ function_call_output ++ base_response_suffix ++ "}\n\n" ++
    "data: [DONE]\n\n";

const stream_error_sse =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":" ++ partial_response ++ "}\n\n" ++
    "event: error\n" ++
    "data: {\"type\":\"error\",\"sequence_number\":1,\"error\":{\"type\":\"error\",\"code\":\"rate_limit_exceeded\",\"message\":\"Rate limit exceeded\",\"param\":null}}\n\n" ++
    "data: [DONE]\n\n";

const stream_failed_sse =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":" ++ partial_response ++ "}\n\n" ++
    "event: response.failed\n" ++
    "data: {\"type\":\"response.failed\",\"sequence_number\":1,\"response\":" ++ failed_response_prefix ++ failed_response_suffix ++ "}\n\n" ++
    "data: [DONE]\n\n";

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

pub const FixtureServer = struct {
    tcp: net.Server,
    port: u16,

    pub fn start(io: Io) !FixtureServer {
        const address: net.IpAddress = .{ .ip4 = .loopback(0) };
        var tcp = try address.listen(io, .{ .reuse_address = true });
        const port = tcp.socket.address.getPort();
        return .{ .tcp = tcp, .port = port };
    }

    pub fn deinit(self: *FixtureServer, io: Io) void {
        self.tcp.deinit(io);
    }

    /// Handle exactly `n` sequential HTTP requests then return.
    pub fn serve(self: *FixtureServer, io: Io, n: usize) !void {
        for (0..n) |_| {
            try self.handleOneRequest(io);
        }
    }

    fn handleOneRequest(self: *FixtureServer, io: Io) !void {
        const stream = try self.tcp.accept(io);
        defer stream.close(io);

        var read_buf: [8192]u8 = undefined;
        var write_buf: [65536]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buf);
        var stream_writer = stream.writer(io, &write_buf);

        var server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

        var request = server.receiveHead() catch return;

        const target = request.head.target;
        const method = request.head.method;
        const content_length = request.head.content_length;

        // Extract scenario header before reading body (body read invalidates head strings)
        var scenario_storage: [64]u8 = undefined;
        var scenario: []const u8 = "text";
        {
            var it = request.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "x-test-scenario")) {
                    const len = @min(h.value.len, scenario_storage.len);
                    @memcpy(scenario_storage[0..len], h.value[0..len]);
                    scenario = scenario_storage[0..len];
                    break;
                }
            }
        }

        // GET /health
        if (method == .GET and std.mem.eql(u8, target, "/health")) {
            try request.respond("{\"status\":\"ok\"}", .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
            return;
        }

        // POST /responses
        if (method == .POST and std.mem.eql(u8, target, "/responses")) {
            // Read body
            // TODO: very large request bodies will still be silently truncated
            var body: []const u8 = "";
            var body_storage: [65536]u8 = undefined;
            if (content_length) |cl| {
                if (cl > 0 and cl <= body_storage.len) {
                    var body_buf: [4096]u8 = undefined;
                    const body_reader = request.readerExpectNone(&body_buf);
                    body_reader.readSliceAll(body_storage[0..cl]) catch {};
                    body = body_storage[0..cl];
                }
            }

            const is_streaming = std.mem.indexOf(u8, body, "\"stream\":true") != null or
                std.mem.indexOf(u8, body, "\"stream\": true") != null;

            const has_tool_result = std.mem.indexOf(u8, body, "function_call_output") != null;

            if (is_streaming) {
                try handleStreaming(&request, scenario, has_tool_result);
            } else {
                try handleNonStreaming(&request, scenario, has_tool_result);
            }
            return;
        }

        // 404
        try request.respond("{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
    }

    fn handleNonStreaming(request: *http.Server.Request, scenario: []const u8, has_tool_result: bool) !void {
        const json_headers: []const http.Header = &.{
            .{ .name = "content-type", .value = "application/json" },
        };

        if (std.mem.eql(u8, scenario, "text")) {
            try request.respond(base_response_prefix ++ text_output ++ base_response_suffix, .{
                .extra_headers = json_headers,
            });
        } else if (std.mem.eql(u8, scenario, "function-call")) {
            try request.respond(base_response_prefix ++ function_call_output ++ base_response_suffix, .{
                .extra_headers = json_headers,
            });
        } else if (std.mem.eql(u8, scenario, "tool-loop")) {
            if (has_tool_result) {
                try request.respond(base_response_prefix ++ tool_loop_text_output ++ base_response_suffix, .{
                    .extra_headers = json_headers,
                });
            } else {
                try request.respond(base_response_prefix ++ tool_loop_fc_output ++ base_response_suffix, .{
                    .extra_headers = json_headers,
                });
            }
        } else if (std.mem.eql(u8, scenario, "done-tool")) {
            try request.respond(base_response_prefix ++ done_tool_output ++ base_response_suffix, .{
                .extra_headers = json_headers,
            });
        } else if (std.mem.eql(u8, scenario, "error")) {
            try request.respond(error_response_body, .{
                .status = .bad_request,
                .extra_headers = json_headers,
            });
        } else if (std.mem.eql(u8, scenario, "failed")) {
            try request.respond(failed_response_prefix ++ failed_response_suffix, .{
                .extra_headers = json_headers,
            });
        } else {
            try request.respond("{\"error\":{\"code\":\"unknown_scenario\"}}", .{
                .status = .bad_request,
                .extra_headers = json_headers,
            });
        }
    }

    fn handleStreaming(request: *http.Server.Request, scenario: []const u8, has_tool_result: bool) !void {
        const sse_headers: []const http.Header = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        };

        if (std.mem.eql(u8, scenario, "text")) {
            try request.respond(text_sse, .{
                .extra_headers = sse_headers,
            });
        } else if (std.mem.eql(u8, scenario, "function-call")) {
            try request.respond(function_call_sse, .{
                .extra_headers = sse_headers,
            });
        } else if (std.mem.eql(u8, scenario, "tool-loop")) {
            if (has_tool_result) {
                try request.respond(text_sse, .{
                    .extra_headers = sse_headers,
                });
            } else {
                try request.respond(function_call_sse, .{
                    .extra_headers = sse_headers,
                });
            }
        } else if (std.mem.eql(u8, scenario, "stream-error")) {
            try request.respond(stream_error_sse, .{
                .extra_headers = sse_headers,
            });
        } else if (std.mem.eql(u8, scenario, "stream-failed")) {
            try request.respond(stream_failed_sse, .{
                .extra_headers = sse_headers,
            });
        } else if (std.mem.eql(u8, scenario, "error")) {
            // Return HTTP 400 error even for streaming requests
            try request.respond(error_response_body, .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
        } else {
            try request.respond("{\"error\":{\"code\":\"unknown_streaming_scenario\"}}", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
        }
    }
};
