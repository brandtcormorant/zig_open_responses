/// Open Responses HTTP client.
///
/// Wraps `std.http.Client` to provide `create()` (non-streaming) and
/// `stream()` (SSE) methods for the Open Responses API, plus helper
/// functions for working with responses.
const std = @import("std");
const json = std.json;
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

const types = @import("types.zig");
const sse = @import("sse.zig");

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

/// Structured error from the Open Responses API.
///
/// Returned when an HTTP request fails (non-2xx status) or when the API
/// returns a response with `status: "failed"`.  Carries the error details
/// so callers can inspect the code, message, and HTTP status.
pub const OpenResponsesError = struct {
    message: []const u8,
    code: []const u8,
    status: u16,
    response: ?types.ResponseResource = null,

    pub fn format(self: OpenResponsesError, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("OpenResponsesError(");
        try writer.writeAll(self.code);
        try writer.writeAll("): ");
        try writer.writeAll(self.message);
    }
};

/// Parse an API error from a JSON response body.
/// Expects `{"error": {"code": "...", "message": "..."}}` format.
/// Falls back to a generic message if parsing fails.
fn parseApiError(arena: Allocator, body: []const u8, status: u16) !OpenResponsesError {
    const value = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch
        return .{ .message = "HTTP error", .code = "http_error", .status = status };

    if (value == .object) {
        if (value.object.get("error")) |err_val| {
            if (err_val == .object) {
                const code = if (err_val.object.get("code")) |c|
                    (if (c == .string) c.string else "unknown")
                else
                    "unknown";
                const message = if (err_val.object.get("message")) |m|
                    (if (m == .string) m.string else "Unknown error")
                else
                    "Unknown error";
                return .{ .message = message, .code = code, .status = status };
            }
        }
    }

    return .{ .message = "HTTP error", .code = "http_error", .status = status };
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub const OpenResponses = struct {
    http_client: http.Client,
    allocator: Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
    model: ?[]const u8,
    extra_headers: []const http.Header,

    pub const Config = struct {
        url: []const u8,
        api_key: ?[]const u8 = null,
        model: ?[]const u8 = null,
        /// Extra HTTP headers sent with every request (useful for testing).
        extra_headers: []const http.Header = &.{},
    };

    pub fn init(allocator: Allocator, io: Io, config: Config) OpenResponses {
        return .{
            .http_client = .{ .io = io, .allocator = allocator },
            .allocator = allocator,
            .base_url = config.url,
            .api_key = config.api_key,
            .model = config.model,
            .extra_headers = config.extra_headers,
        };
    }

    pub fn deinit(self: *OpenResponses) void {
        self.http_client.deinit();
    }

    // ----- Request helpers ------------------------------------------------

    fn buildUrl(self: *OpenResponses, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/responses", .{self.base_url});
    }

    fn buildAuthValue(self: *OpenResponses, arena: Allocator) !?[]const u8 {
        return if (self.api_key) |key|
            try std.fmt.allocPrint(arena, "Bearer {s}", .{key})
        else
            null;
    }

    fn buildHeaders(self: *OpenResponses, arena: Allocator, auth_value: ?[]const u8) ![]const http.Header {
        var list = std.ArrayList(http.Header).empty;
        try list.append(arena, .{ .name = "content-type", .value = "application/json" });
        if (auth_value) |av| {
            try list.append(arena, .{ .name = "authorization", .value = av });
        }
        for (self.extra_headers) |h| {
            try list.append(arena, h);
        }
        return list.items;
    }

    // ----- Result types ---------------------------------------------------

    /// Result of a `create()` call — either a successful response or an
    /// API error (non-2xx HTTP status with error details).
    pub const CreateResult = union(enum) {
        response: types.ResponseResource,
        api_error: OpenResponsesError,
    };

    // ----- Non-streaming -------------------------------------------------

    /// Sends a non-streaming request to POST /responses.
    ///
    /// Returns a `CreateResult`: `.response` on success, `.api_error` on
    /// non-2xx HTTP status.  The returned data and all strings it
    /// references are allocated in `arena`.
    pub fn create(
        self: *OpenResponses,
        arena: Allocator,
        params: types.CreateResponseBody,
    ) !CreateResult {
        // Serialize the request body
        var body = params;
        body.model = body.model orelse self.model;
        body.stream = false;

        var ser_writer: Io.Writer.Allocating = .init(arena);
        var jws: json.Stringify = .{
            .writer = &ser_writer.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        jws.write(body) catch return error.RequestSerializationFailed;
        const payload = ser_writer.written();

        const url = try self.buildUrl(arena);
        const auth_value = try self.buildAuthValue(arena);
        const headers = try self.buildHeaders(arena, auth_value);

        // Fetch
        var resp_writer: Io.Writer.Allocating = .init(arena);

        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .extra_headers = headers,
            .response_writer = &resp_writer.writer,
            .keep_alive = false,
        });

        const response_body = resp_writer.written();

        // Check HTTP status
        if (result.status.class() != .success) {
            return .{
                .api_error = try parseApiError(arena, response_body, @intFromEnum(result.status)),
            };
        }

        // Parse
        const value = json.parseFromSliceLeaky(json.Value, arena, response_body, .{}) catch
            return error.ResponseParseFailed;
        const resource = json.parseFromValueLeaky(
            types.ResponseResource,
            arena,
            value,
            .{ .ignore_unknown_fields = true },
        ) catch return error.ResponseParseFailed;

        return .{ .response = resource };
    }

    // ----- Streaming -----------------------------------------------------

    /// A streaming response — wraps the HTTP connection and an SSE parser.
    ///
    /// Call `next()` to get typed `StreamingEvent` values.  When done (or
    /// on error), call `deinit()` to release the connection back to the
    /// pool.
    ///
    /// Heap-allocated so that internal pointers (the reader references
    /// `transfer_buf` and `response`) remain stable.
    pub const Stream = struct {
        request: http.Client.Request,
        response: http.Client.Response,
        parser: sse.SseParser,
        transfer_buf: [8192]u8,
        allocator: Allocator,

        pub fn next(self: *Stream) !?types.StreamingEvent {
            return self.parser.nextEvent();
        }

        pub fn deinit(self: *Stream) void {
            self.parser.deinit();
            self.request.deinit();
            const alloc = self.allocator;
            alloc.destroy(self);
        }
    };

    /// Result of a `stream()` call — either a Stream or an API error.
    pub const StreamResult = union(enum) {
        stream: *Stream,
        api_error: OpenResponsesError,
    };

    /// Sends a streaming request to POST /responses.
    ///
    /// Returns a `StreamResult`: `.stream` on success whose `next()`
    /// method yields typed `StreamingEvent` values, or `.api_error` on
    /// non-2xx HTTP status.  The caller must call `stream.deinit()` when
    /// done.
    ///
    /// Strings inside the events are allocated in `arena`.
    pub fn stream(
        self: *OpenResponses,
        arena: Allocator,
        params: types.CreateResponseBody,
    ) !StreamResult {
        var body = params;
        body.model = body.model orelse self.model;
        body.stream = true;

        // Serialize
        var ser_writer: Io.Writer.Allocating = .init(arena);
        var jws: json.Stringify = .{
            .writer = &ser_writer.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        jws.write(body) catch return error.StreamSetupFailed;
        const payload = ser_writer.written();

        const url = try self.buildUrl(arena);
        const auth_value = try self.buildAuthValue(arena);
        const headers = try self.buildHeaders(arena, auth_value);
        const uri = Uri.parse(url) catch return error.StreamSetupFailed;

        // Open request
        var req = try self.http_client.request(.POST, uri, .{
            .extra_headers = headers,
            .keep_alive = false,
        });
        errdefer req.deinit();

        // Send body
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        if (req.connection) |conn| conn.flush() catch {};

        // Receive head
        var redirect_buf: [0]u8 = undefined;
        const response = req.receiveHead(&redirect_buf) catch
            return error.StreamSetupFailed;

        // Check HTTP status
        if (response.head.status.class() != .success) {
            // Read error body from the connection
            var err_transfer_buf: [4096]u8 = undefined;
            var err_response = response;
            err_response.request = &req;
            const err_reader = err_response.reader(&err_transfer_buf);
            const err_body = err_reader.allocRemaining(arena, .limited(65536)) catch "";
            req.deinit();
            return .{
                .api_error = try parseApiError(arena, err_body, @intFromEnum(response.head.status)),
            };
        }

        // Heap-allocate the Stream so internal pointers (reader into
        // transfer_buf / response) remain stable after returning.
        const s = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(s);
        s.* = .{
            .request = req,
            .response = response,
            .parser = undefined,
            .transfer_buf = undefined,
            .allocator = self.allocator,
        };
        // Fix up the response's back-pointer to request — it was
        // pointing at the now-gone stack local; redirect it to the
        // heap copy.
        s.response.request = &s.request;
        const body_reader = s.response.reader(&s.transfer_buf);
        s.parser = sse.SseParser.init(arena, body_reader);

        return .{ .stream = s };
    }

    // ----- streamText convenience -----------------------------------------

    /// Result of a `streamText()` call.
    pub const StreamTextResult = union(enum) {
        /// Successful result with concatenated text and the final response.
        result: struct {
            text: []const u8,
            response: types.ResponseResource,
        },
        /// HTTP-level API error.
        api_error: OpenResponsesError,
        /// A response.failed event was received.
        response_failed: types.ResponseResource,
        /// An error event was received in the stream.
        stream_error: types.ErrorPayload,
        /// Stream ended without a response.completed or response.incomplete event.
        incomplete_stream: void,
    };

    /// Streams a response and collects the full text output.
    ///
    /// Opens a streaming connection, concatenates all
    /// `response.output_text.delta` events into a single string, and
    /// returns it along with the final `ResponseResource`.
    ///
    /// All allocations go into `arena`.
    pub fn streamText(
        self: *OpenResponses,
        arena: Allocator,
        params: types.CreateResponseBody,
    ) !StreamTextResult {
        const stream_result = try self.stream(arena, params);

        switch (stream_result) {
            .api_error => |err| return .{ .api_error = err },
            .stream => |s| {
                defer s.deinit();

                var text_buf = std.ArrayList(u8).empty;
                var final_response: ?types.ResponseResource = null;

                while (try s.next()) |event| {
                    switch (event) {
                        .@"response.output_text.delta" => |e| {
                            try text_buf.appendSlice(arena, e.delta);
                        },
                        .@"response.completed" => |e| {
                            final_response = e.response;
                        },
                        .@"response.incomplete" => |e| {
                            final_response = e.response;
                        },
                        .@"response.failed" => |e| {
                            return .{ .response_failed = e.response };
                        },
                        .@"error" => |e| {
                            return .{ .stream_error = e.@"error" };
                        },
                        else => {},
                    }
                }

                const resp = final_response orelse
                    return .incomplete_stream;

                return .{ .result = .{
                    .text = text_buf.items,
                    .response = resp,
                } };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Extracts the concatenated text from all output_text content parts
/// across all message items in a response.
pub fn getOutputText(response: types.ResponseResource) []const u8 {
    // We can't allocate, so we return the first text part we find.
    // For multi-part responses the caller should iterate manually.
    for (response.output) |item| {
        switch (item) {
            .message => |msg| {
                for (msg.content) |part| {
                    switch (part) {
                        .output_text => |t| return t.text,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return "";
}

/// Collects all text from output_text content parts, concatenated with
/// the given allocator.
pub fn getOutputTextAlloc(allocator: Allocator, response: types.ResponseResource) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    for (response.output) |item| {
        switch (item) {
            .message => |msg| {
                for (msg.content) |part| {
                    switch (part) {
                        .output_text => |t| try buf.appendSlice(allocator, t.text),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Returns true if any output item is a function_call.
pub fn hasFunctionCalls(response: types.ResponseResource) bool {
    for (response.output) |item| {
        switch (item) {
            .function_call => return true,
            else => {},
        }
    }
    return false;
}

/// Collects function_call items from a response into an allocated slice.
pub fn extractFunctionCallsAlloc(allocator: Allocator, response: types.ResponseResource) ![]types.FunctionCallItem {
    var list = std.ArrayList(types.FunctionCallItem).empty;
    for (response.output) |item| {
        switch (item) {
            .function_call => |fc| try list.append(allocator, fc),
            else => {},
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Normalizes input: a string becomes a single user message item array.
/// If the input is already an items array, returns it as-is.
/// If null, returns an empty slice.
pub fn normalizeInput(allocator: Allocator, input: ?types.Input) ![]const types.ItemParam {
    const inp = input orelse return &.{};
    return switch (inp) {
        .items => |items| items,
        .string => |s| blk: {
            const items = try allocator.alloc(types.ItemParam, 1);
            items[0] = .{ .message = .{ .user = .{ .role = .user, .content = .{ .string = s } } } };
            break :blk items;
        },
    };
}

/// Returns true if the response has a failed status or a non-null error field.
pub fn isError(response: types.ResponseResource) bool {
    return response.status == .failed or response.@"error" != null;
}

/// Returns true if the response has an incomplete status.
pub fn isIncomplete(response: types.ResponseResource) bool {
    return response.status == .incomplete;
}

/// Creates a function tool definition.
pub fn functionTool(
    name: []const u8,
    description: ?[]const u8,
    parameters: ?json.Value,
) types.Tool {
    return .{
        .function = .{
            .name = name,
            .description = description,
            .parameters = parameters,
        },
    };
}

/// Build an array of types.Tool from ToolHandler descriptions.
/// Only includes handlers that have description and parameters_json set.
pub fn toolDefsFromHandlers(allocator: Allocator, handlers: []const ToolHandler) ![]const types.Tool {
    var list = std.ArrayList(types.Tool).empty;
    for (handlers) |h| {
        const desc = h.description orelse continue;
        const params_json = h.parameters_json orelse continue;
        const params = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch continue;
        try list.append(allocator, .{
            .function = .{
                .name = h.name,
                .description = desc,
                .parameters = params.value,
            },
        });
    }
    return list.items;
}

// ---------------------------------------------------------------------------
// Item conversion
// ---------------------------------------------------------------------------

/// Converts an output ItemField to an input ItemParam for multi-turn
/// conversation building.  This is needed when accumulating context:
/// the model's output items must be fed back as input items.
pub fn itemFieldToParam(allocator: Allocator, field: types.ItemField) !types.ItemParam {
    return switch (field) {
        .function_call => |fc| .{ .function_call = .{
            .call_id = fc.call_id,
            .name = fc.name,
            .arguments = fc.arguments,
            .id = fc.id,
            .status = fc.status,
        } },
        .function_call_output => |fco| .{ .function_call_output = .{
            .call_id = fco.call_id,
            .output = .{ .string = fco.output },
            .id = fco.id,
            .status = fco.status,
        } },
        .message => |msg| .{ .message = .{ .assistant = .{
            .content = try convertContentParts(allocator, msg.content),
            .id = msg.id,
        } } },
        .reasoning => |r| .{ .reasoning = .{
            .summary = r.summary,
            .id = r.id,
            .encrypted_content = r.encrypted_content,
        } },
    };
}

/// Converts output ContentPart slice to OutputContentOrString for assistant messages.
///
/// Extracts output_text and refusal parts from the ContentPart slice,
/// allocating the result on the provided allocator (typically an arena).
fn convertContentParts(allocator: Allocator, parts: []const types.ContentPart) !types.OutputContentOrString {
    var output_list = std.ArrayList(types.OutputContent).empty;
    for (parts) |part| {
        switch (part) {
            .output_text => |t| try output_list.append(allocator, .{ .output_text = t }),
            .refusal => |r| try output_list.append(allocator, .{ .refusal = r }),
            else => {},
        }
    }

    if (output_list.items.len == 0) {
        return .{ .string = "" };
    }

    return .{ .parts = output_list.items };
}

/// Converts output ItemField slice to input ItemParam slice (allocating).
pub fn itemFieldsToParams(allocator: Allocator, fields: []const types.ItemField) ![]types.ItemParam {
    var list = std.ArrayList(types.ItemParam).empty;

    for (fields) |field| {
        try list.append(allocator, try itemFieldToParam(allocator, field));
    }

    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tool loop
// ---------------------------------------------------------------------------

/// Result from a tool handler invocation.
pub const ToolResult = union(enum) {
    /// Successful output string to feed back to the model.
    output: []const u8,
    /// Error message to feed back to the model.
    @"error": []const u8,
};

/// A tool handler: a named function that the tool loop can call.
pub const ToolHandler = struct {
    name: []const u8,
    callback: *const fn (ctx: *anyopaque, name: []const u8, arguments: []const u8) anyerror!ToolResult,
    ctx: *anyopaque,
    /// Tool description for LLM schema generation. Optional for backward compatibility.
    description: ?[]const u8 = null,
    /// JSON Schema string for tool parameters. Optional for backward compatibility.
    parameters_json: ?[]const u8 = null,

    /// Returns a Tool definition for inclusion in API requests.
    /// Requires description and parameters_json to be set.
    pub fn toFunctionTool(self: ToolHandler) ?types.Tool {
        const desc = self.description orelse return null;
        const params_json = self.parameters_json orelse return null;
        const params = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, params_json, .{}) catch return null;
        return .{ .function = .{
            .name = self.name,
            .description = desc,
            .parameters = params.value,
        } };
    }
};

/// Generate a ToolHandler from a typed struct at comptime.
///
/// The type T must declare:
///   - `pub const tool_name: []const u8`
///   - `pub const tool_description: []const u8`
///   - `pub const tool_params: []const u8` (JSON Schema)
///   - `pub fn execute(self: *T, name: []const u8, arguments: []const u8) anyerror!ToolResult`
pub fn toolHandler(comptime T: type, instance: *T) ToolHandler {
    return .{
        .name = T.tool_name,
        .callback = &struct {
            fn f(ctx: *anyopaque, n: []const u8, args: []const u8) anyerror!ToolResult {
                const self: *T = @ptrCast(@alignCast(ctx));
                return self.execute(n, args);
            }
        }.f,
        .ctx = @ptrCast(instance),
        .description = T.tool_description,
        .parameters_json = T.tool_params,
    };
}

/// Bundled response callback for tool loop notifications.
pub const OnResponseCallback = struct {
    callback: *const fn (ctx: *anyopaque, response: types.ResponseResource, turn: u32) void,
    ctx: *anyopaque,
};

/// Options for the tool loop.
pub const ToolLoopOptions = struct {
    max_turns: u32 = 10,
    on_response: ?OnResponseCallback = null,
    /// When set, the loop terminates when the model calls a tool with this
    /// name. Any other tool calls in the same response are still executed
    /// and their results are returned in `done_tool_results`.
    done_tool_name: ?[]const u8 = null,
    /// Called after each tool execution turn. Returns items to inject
    /// before the next LLM call. Empty slice = no steering.
    get_steering: ?*const fn (ctx: *anyopaque) []const types.ItemParam = null,
    steering_ctx: ?*anyopaque = null,
    /// Called when the model stops calling tools and no steering is pending.
    /// Returns items to continue the conversation. Empty slice = done.
    get_follow_ups: ?*const fn (ctx: *anyopaque) []const types.ItemParam = null,
    follow_up_ctx: ?*anyopaque = null,
};

/// Result payload for a completed response, optionally with done-tool results.
pub const ResponseWithToolResults = struct {
    response: types.ResponseResource,
    /// Tool outputs from the final turn when `done_tool_name` triggered
    /// early termination. Null when the loop ended naturally.
    done_tool_results: ?[]const types.ItemParam = null,
};

/// Result of a completed tool loop.
pub const ToolLoopResult = union(enum) {
    /// The final response (no more tool calls), optionally with done-tool results.
    response: ResponseWithToolResults,
    /// An API error occurred during one of the create() calls.
    api_error: OpenResponsesError,
    /// The loop exceeded max_turns.
    max_turns_exceeded: void,
};

/// Executes tool handlers for a set of function calls, producing
/// function_call_output items to feed back as input.
pub fn executeTools(
    allocator: Allocator,
    function_calls: []const types.FunctionCallItem,
    handlers: []const ToolHandler,
) ![]types.ItemParam {
    var results = std.ArrayList(types.ItemParam).empty;

    for (function_calls) |fc| {
        const handler = findHandler(handlers, fc.name);
        if (handler) |h| {
            const output_str = if (h.callback(h.ctx, fc.name, fc.arguments)) |result|
                switch (result) {
                    .output => |o| o,
                    .@"error" => |e| e,
                }
            else |_|
                "{\"error\":\"Handler returned an error\"}";

            try results.append(allocator, .{
                .function_call_output = .{
                    .call_id = fc.call_id,
                    .output = .{ .string = output_str },
                },
            });
        } else {
            try results.append(allocator, .{
                .function_call_output = .{
                    .call_id = fc.call_id,
                    .output = .{ .string = "{\"error\":\"No handler registered\"}" },
                },
            });
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Detects responses that promise action without issuing tool calls.
/// Checks for common phrases like "I'll try", "Let me check", etc.
fn looksLikeUnfulfilledPromise(text: []const u8) bool {
    const needles = [_][]const u8{
        "I'll try",
        "I'll check",
        "I'll look",
        "I'll search",
        "I'll run",
        "I'll execute",
        "I'll read",
        "I'll write",
        "Let me try",
        "Let me check",
        "Let me look",
        "Let me search",
        "Let me run",
        "Let me read",
        "let me try",
        "let me check",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn findHandler(handlers: []const ToolHandler, name: []const u8) ?ToolHandler {
    for (handlers) |h| {
        if (std.mem.eql(u8, h.name, name)) return h;
    }
    return null;
}

fn containsTool(fcs: []const types.FunctionCallItem, name: []const u8) bool {
    for (fcs) |fc| {
        if (std.mem.eql(u8, fc.name, name)) return true;
    }
    return false;
}

fn filterOutTool(allocator: Allocator, fcs: []const types.FunctionCallItem, name: []const u8) ![]const types.FunctionCallItem {
    var list = std.ArrayList(types.FunctionCallItem).empty;
    for (fcs) |fc| {
        if (!std.mem.eql(u8, fc.name, name)) {
            try list.append(allocator, fc);
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Converts an optional Input into a mutable ArrayList of ItemParam.
fn initInputList(allocator: Allocator, input: ?types.Input) !std.ArrayList(types.ItemParam) {
    var list = std.ArrayList(types.ItemParam).empty;
    if (input) |inp| {
        switch (inp) {
            .items => |items| {
                for (items) |item| {
                    try list.append(allocator, item);
                }
            },
            .string => |s| {
                try list.append(allocator, .{
                    .message = .{ .user = .{ .role = .user, .content = .{ .string = s } } },
                });
            },
        }
    }
    return list;
}

/// Runs the agentic tool-call loop (non-streaming).
///
/// Sends a request via `create()`, checks for function calls, executes
/// handlers, feeds results back, and repeats until the model produces a
/// response with no tool calls or the turn limit is reached.
///
/// All allocations go into `arena`.
pub fn toolLoop(
    client: *OpenResponses,
    arena: Allocator,
    params: types.CreateResponseBody,
    handlers: []const ToolHandler,
    options: ToolLoopOptions,
) !ToolLoopResult {
    var input_list = try initInputList(arena, params.input);
    var turn: u32 = 0;
    var empty_retries: u32 = 0;
    var follow_through_retries: u32 = 0;

    while (turn < options.max_turns) {
        // Build params for this turn
        var turn_params = params;
        turn_params.input = .{ .items = input_list.items };

        const result = try client.create(arena, turn_params);

        switch (result) {
            .api_error => |err| return .{ .api_error = err },
            .response => |resp| {
                turn += 1;

                if (options.on_response) |cb| {
                    cb.callback(cb.ctx, resp, turn);
                }

                const fcs = try extractFunctionCallsAlloc(arena, resp);

                if (fcs.len == 0) {
                    const response_text = getOutputText(resp);

                    // Guardrail: empty response retry (max 1)
                    if (response_text.len == 0 and empty_retries < 1 and turn < options.max_turns) {
                        empty_retries += 1;
                        const out_params = try itemFieldsToParams(arena, resp.output);
                        for (out_params) |p| {
                            try input_list.append(arena, p);
                        }
                        try input_list.append(arena, .{
                            .message = .{ .user = .{
                                .role = .user,
                                .content = .{ .string = "Your previous reply was empty. Respond with a direct answer or emit the necessary tool calls." },
                            } },
                        });
                        continue;
                    }

                    // Guardrail: forced follow-through (max 2)
                    if (response_text.len > 0 and follow_through_retries < 2 and turn < options.max_turns and
                        looksLikeUnfulfilledPromise(response_text))
                    {
                        follow_through_retries += 1;
                        const out_params = try itemFieldsToParams(arena, resp.output);
                        for (out_params) |p| {
                            try input_list.append(arena, p);
                        }
                        try input_list.append(arena, .{
                            .message = .{ .user = .{
                                .role = .user,
                                .content = .{ .string = "You just promised to take action but did not issue any tool calls. Issue the appropriate tool calls now, or state the limitation clearly." },
                            } },
                        });
                        continue;
                    }

                    // Check steering before stopping
                    if (options.get_steering) |get_steer| {
                        const steering = get_steer(options.steering_ctx.?);
                        if (steering.len > 0) {
                            const out_params = try itemFieldsToParams(arena, resp.output);
                            for (out_params) |p| {
                                try input_list.append(arena, p);
                            }
                            for (steering) |item| {
                                try input_list.append(arena, item);
                            }
                            continue;
                        }
                    }

                    // Check follow-ups before stopping
                    if (options.get_follow_ups) |get_fu| {
                        const follow_ups = get_fu(options.follow_up_ctx.?);
                        if (follow_ups.len > 0) {
                            const out_params = try itemFieldsToParams(arena, resp.output);
                            for (out_params) |p| {
                                try input_list.append(arena, p);
                            }
                            for (follow_ups) |item| {
                                try input_list.append(arena, item);
                            }
                            continue;
                        }
                    }

                    return .{ .response = .{ .response = resp } };
                }

                if (options.done_tool_name) |done_name| {
                    if (containsTool(fcs, done_name)) {
                        const active = try filterOutTool(arena, fcs, done_name);
                        const done_results = if (active.len > 0)
                            try executeTools(arena, active, handlers)
                        else
                            null;
                        return .{ .response = .{
                            .response = resp,
                            .done_tool_results = done_results,
                        } };
                    }
                }

                const output_params = try itemFieldsToParams(arena, resp.output);
                for (output_params) |p| {
                    try input_list.append(arena, p);
                }

                const tool_results = try executeTools(arena, fcs, handlers);
                for (tool_results) |tr| {
                    try input_list.append(arena, tr);
                }

                // Check steering after tool execution
                if (options.get_steering) |get_steer| {
                    const steering = get_steer(options.steering_ctx.?);
                    for (steering) |item| {
                        try input_list.append(arena, item);
                    }
                }
            },
        }
    }

    return .max_turns_exceeded;
}

// ---------------------------------------------------------------------------
// Streaming tool loop
// ---------------------------------------------------------------------------

/// Callback invoked for each streaming event during the streaming tool loop.
pub const OnStreamEvent = *const fn (ctx: *anyopaque, event: types.StreamingEvent, turn: u32) void;

/// Result of a completed streaming tool loop.
pub const StreamToolLoopResult = union(enum) {
    /// The final response (no more tool calls), optionally with done-tool results.
    response: ResponseWithToolResults,
    /// An API error occurred (HTTP-level).
    api_error: OpenResponsesError,
    /// The loop exceeded max_turns.
    max_turns_exceeded: void,
    /// The stream ended without a response.completed event.
    incomplete_stream: void,
    /// A response.failed event was received.
    response_failed: types.ResponseResource,
    /// An error event was received in the stream.
    stream_error: types.ErrorPayload,
};

/// Runs the agentic tool-call loop with streaming.
///
/// Each turn opens a streaming connection. Events are forwarded to the
/// `on_event` callback.  When `response.completed` is received, the
/// response is checked for function calls.  If any, handlers are
/// executed and a new streaming turn begins.
///
/// All allocations go into `arena`.
pub fn streamToolLoop(
    client: *OpenResponses,
    arena: Allocator,
    params: types.CreateResponseBody,
    handlers: []const ToolHandler,
    on_event: OnStreamEvent,
    on_event_ctx: *anyopaque,
    options: ToolLoopOptions,
) !StreamToolLoopResult {
    var input_list = try initInputList(arena, params.input);
    var turn: u32 = 0;
    var empty_retries: u32 = 0;
    var follow_through_retries: u32 = 0;

    while (turn < options.max_turns) {
        var turn_params = params;
        turn_params.input = .{ .items = input_list.items };

        const stream_result = try client.stream(arena, turn_params);

        switch (stream_result) {
            .api_error => |err| return .{ .api_error = err },
            .stream => |s| {
                defer s.deinit();
                turn += 1;

                var completed_response: ?types.ResponseResource = null;

                while (try s.next()) |event| {
                    // Forward to callback
                    on_event(on_event_ctx, event, turn);

                    switch (event) {
                        .@"response.completed" => |e| {
                            completed_response = e.response;
                        },
                        .@"response.incomplete" => |e| {
                            completed_response = e.response;
                        },
                        .@"response.failed" => |e| {
                            return .{ .response_failed = e.response };
                        },
                        .@"error" => |e| {
                            return .{ .stream_error = e.@"error" };
                        },
                        else => {},
                    }
                }

                const resp = completed_response orelse
                    return .incomplete_stream;

                const fcs = try extractFunctionCallsAlloc(arena, resp);

                if (fcs.len == 0) {
                    const response_text = getOutputText(resp);

                    // Guardrail: empty response retry (max 1)
                    if (response_text.len == 0 and empty_retries < 1 and turn < options.max_turns) {
                        empty_retries += 1;
                        const out_params = try itemFieldsToParams(arena, resp.output);
                        for (out_params) |p| {
                            try input_list.append(arena, p);
                        }
                        try input_list.append(arena, .{
                            .message = .{ .user = .{
                                .role = .user,
                                .content = .{ .string = "Your previous reply was empty. Respond with a direct answer or emit the necessary tool calls." },
                            } },
                        });
                        continue;
                    }

                    // Guardrail: forced follow-through (max 2)
                    if (response_text.len > 0 and follow_through_retries < 2 and turn < options.max_turns and
                        looksLikeUnfulfilledPromise(response_text))
                    {
                        follow_through_retries += 1;
                        const out_params = try itemFieldsToParams(arena, resp.output);
                        for (out_params) |p| {
                            try input_list.append(arena, p);
                        }
                        try input_list.append(arena, .{
                            .message = .{ .user = .{
                                .role = .user,
                                .content = .{ .string = "You just promised to take action but did not issue any tool calls. Issue the appropriate tool calls now, or state the limitation clearly." },
                            } },
                        });
                        continue;
                    }

                    // Check steering before stopping
                    if (options.get_steering) |get_steer| {
                        const steering = get_steer(options.steering_ctx.?);
                        if (steering.len > 0) {
                            const out_params = try itemFieldsToParams(arena, resp.output);
                            for (out_params) |p| {
                                try input_list.append(arena, p);
                            }
                            for (steering) |item| {
                                try input_list.append(arena, item);
                            }
                            continue;
                        }
                    }

                    // Check follow-ups before stopping
                    if (options.get_follow_ups) |get_fu| {
                        const follow_ups = get_fu(options.follow_up_ctx.?);
                        if (follow_ups.len > 0) {
                            const out_params = try itemFieldsToParams(arena, resp.output);
                            for (out_params) |p| {
                                try input_list.append(arena, p);
                            }
                            for (follow_ups) |item| {
                                try input_list.append(arena, item);
                            }
                            continue;
                        }
                    }

                    return .{ .response = .{ .response = resp } };
                }

                if (options.done_tool_name) |done_name| {
                    if (containsTool(fcs, done_name)) {
                        const active = try filterOutTool(arena, fcs, done_name);
                        const done_results = if (active.len > 0)
                            try executeTools(arena, active, handlers)
                        else
                            null;
                        return .{ .response = .{
                            .response = resp,
                            .done_tool_results = done_results,
                        } };
                    }
                }

                const output_params = try itemFieldsToParams(arena, resp.output);
                for (output_params) |p| {
                    try input_list.append(arena, p);
                }

                const tool_results = try executeTools(arena, fcs, handlers);

                for (tool_results) |tr| {
                    try input_list.append(arena, tr);
                }

                // Check steering after tool execution
                if (options.get_steering) |get_steer| {
                    const steering = get_steer(options.steering_ctx.?);

                    for (steering) |item| {
                        try input_list.append(arena, item);
                    }
                }
            },
        }
    }

    return .max_turns_exceeded;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getOutputText returns first text" {
    const response = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .completed,
        .model = "m",
        .output = &.{
            .{ .message = .{
                .id = "msg_1",
                .status = .completed,
                .role = .assistant,
                .content = &.{
                    .{ .output_text = .{ .text = "Hello!", .annotations = &.{} } },
                },
            } },
        },
    };

    const text = getOutputText(response);
    try std.testing.expectEqualStrings("Hello!", text);
}

test "getOutputText returns empty for no messages" {
    const response = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .completed,
        .model = "m",
        .output = &.{},
    };

    const text = getOutputText(response);
    try std.testing.expectEqualStrings("", text);
}

test "hasFunctionCalls" {
    const with_fc = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .completed,
        .model = "m",
        .output = &.{
            .{ .function_call = .{
                .id = "fc_1",
                .call_id = "call_1",
                .name = "get_weather",
                .arguments = "{}",
                .status = .completed,
            } },
        },
    };
    try std.testing.expect(hasFunctionCalls(with_fc));

    const without_fc = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .completed,
        .model = "m",
        .output = &.{},
    };
    try std.testing.expect(!hasFunctionCalls(without_fc));
}

test "isError detects failed status" {
    const failed = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .failed,
        .model = "m",
        .output = &.{},
        .@"error" = .{ .code = "server_error", .message = "Internal error" },
    };
    try std.testing.expect(isError(failed));

    const ok = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .completed,
        .model = "m",
        .output = &.{},
    };
    try std.testing.expect(!isError(ok));

    // Error field set but status not failed — still an error
    const error_field_only = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .completed,
        .model = "m",
        .output = &.{},
        .@"error" = .{ .code = "weird", .message = "odd" },
    };
    try std.testing.expect(isError(error_field_only));
}

test "isIncomplete detects incomplete status" {
    const incomplete = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .incomplete,
        .model = "m",
        .output = &.{},
        .incomplete_details = .{ .reason = "max_tokens" },
    };
    try std.testing.expect(isIncomplete(incomplete));

    const ok = types.ResponseResource{
        .id = "resp_1",
        .created_at = 0,
        .status = .completed,
        .model = "m",
        .output = &.{},
    };
    try std.testing.expect(!isIncomplete(ok));
}

test "itemFieldToParam converts function_call" {
    const fc_field = types.ItemField{
        .function_call = .{
            .id = "fc_1",
            .call_id = "call_1",
            .name = "get_weather",
            .arguments = "{\"city\":\"SF\"}",
            .status = .completed,
        },
    };
    const param = try itemFieldToParam(std.testing.allocator, fc_field);
    switch (param) {
        .function_call => |fc| {
            try std.testing.expectEqualStrings("call_1", fc.call_id);
            try std.testing.expectEqualStrings("get_weather", fc.name);
            try std.testing.expectEqualStrings("{\"city\":\"SF\"}", fc.arguments);
        },
        else => return error.UnexpectedResult,
    }
}

test "itemFieldToParam converts function_call_output" {
    const fco_field = types.ItemField{
        .function_call_output = .{
            .id = "fco_1",
            .call_id = "call_1",
            .output = "22C",
            .status = .completed,
        },
    };
    const param = try itemFieldToParam(std.testing.allocator, fco_field);
    switch (param) {
        .function_call_output => |fco| {
            try std.testing.expectEqualStrings("call_1", fco.call_id);
            switch (fco.output) {
                .string => |s| try std.testing.expectEqualStrings("22C", s),
                else => return error.UnexpectedResult,
            }
        },
        else => return error.UnexpectedResult,
    }
}

test "itemFieldToParam converts message with output_text content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const msg_field = types.ItemField{
        .message = .{
            .id = "msg_1",
            .status = .completed,
            .role = .assistant,
            .content = &.{
                .{ .output_text = .{ .text = "Hello " } },
                .{ .output_text = .{ .text = "world!" } },
            },
        },
    };
    const param = try itemFieldToParam(alloc, msg_field);
    switch (param) {
        .message => |msg| {
            switch (msg) {
                .assistant => |a| {
                    switch (a.content) {
                        .parts => |parts| {
                            try std.testing.expect(parts.len == 2);
                            switch (parts[0]) {
                                .output_text => |t| try std.testing.expectEqualStrings("Hello ", t.text),
                                else => return error.UnexpectedResult,
                            }
                            switch (parts[1]) {
                                .output_text => |t| try std.testing.expectEqualStrings("world!", t.text),
                                else => return error.UnexpectedResult,
                            }
                        },
                        .string => return error.UnexpectedResult,
                    }
                },
                else => return error.UnexpectedResult,
            }
        },
        else => return error.UnexpectedResult,
    }
}

test "itemFieldToParam reasoning round-trip preserves encrypted_content" {
    const reasoning_field = types.ItemField{
        .reasoning = .{
            .id = "rs_1",
            .summary = &.{.{ .type = "summary_text", .text = "Thinking..." }},
            .encrypted_content = "opaque_blob_abc",
        },
    };
    const param = try itemFieldToParam(std.testing.allocator, reasoning_field);
    switch (param) {
        .reasoning => |r| {
            try std.testing.expectEqualStrings("rs_1", r.id.?);
            try std.testing.expectEqualStrings("opaque_blob_abc", r.encrypted_content.?);
            try std.testing.expect(r.summary != null);
            try std.testing.expect(r.summary.?.len == 1);
        },
        else => return error.UnexpectedResult,
    }
}

test "executeTools calls handler and returns output" {
    const Handler = struct {
        fn callback(_: *anyopaque, _: []const u8, _: []const u8) anyerror!ToolResult {
            return .{ .output = "{\"temp\":\"22C\"}" };
        }
    };
    var dummy_ctx: u8 = 0;
    const handlers = [_]ToolHandler{
        .{ .name = "get_weather", .callback = &Handler.callback, .ctx = @ptrCast(&dummy_ctx) },
    };
    const fcs = [_]types.FunctionCallItem{
        .{
            .id = "fc_1",
            .call_id = "call_1",
            .name = "get_weather",
            .arguments = "{}",
            .status = .completed,
        },
    };

    const results = try executeTools(std.testing.allocator, &fcs, &handlers);
    defer std.testing.allocator.free(results);

    try std.testing.expect(results.len == 1);
    switch (results[0]) {
        .function_call_output => |fco| {
            try std.testing.expectEqualStrings("call_1", fco.call_id);
            switch (fco.output) {
                .string => |s| try std.testing.expectEqualStrings("{\"temp\":\"22C\"}", s),
                else => return error.UnexpectedResult,
            }
        },
        else => return error.UnexpectedResult,
    }
}

test "executeTools returns error for missing handler" {
    const fcs = [_]types.FunctionCallItem{
        .{
            .id = "fc_1",
            .call_id = "call_1",
            .name = "unknown_func",
            .arguments = "{}",
            .status = .completed,
        },
    };

    const results = try executeTools(std.testing.allocator, &fcs, &.{});
    defer std.testing.allocator.free(results);

    try std.testing.expect(results.len == 1);
    switch (results[0]) {
        .function_call_output => |fco| {
            switch (fco.output) {
                .string => |s| try std.testing.expect(std.mem.indexOf(u8, s, "No handler") != null),
                else => return error.UnexpectedResult,
            }
        },
        else => return error.UnexpectedResult,
    }
}

test "executeTools catches handler error" {
    const ErrHandler = struct {
        fn callback(_: *anyopaque, _: []const u8, _: []const u8) anyerror!ToolResult {
            return error.SomethingFailed;
        }
    };
    var dummy_ctx: u8 = 0;
    const handlers = [_]ToolHandler{
        .{ .name = "failing_tool", .callback = &ErrHandler.callback, .ctx = @ptrCast(&dummy_ctx) },
    };
    const fcs = [_]types.FunctionCallItem{
        .{
            .id = "fc_1",
            .call_id = "call_err",
            .name = "failing_tool",
            .arguments = "{}",
            .status = .completed,
        },
    };

    const results = try executeTools(std.testing.allocator, &fcs, &handlers);
    defer std.testing.allocator.free(results);

    try std.testing.expect(results.len == 1);
    switch (results[0]) {
        .function_call_output => |fco| {
            try std.testing.expectEqualStrings("call_err", fco.call_id);
            switch (fco.output) {
                .string => |s| try std.testing.expect(std.mem.indexOf(u8, s, "Handler returned an error") != null),
                else => return error.UnexpectedResult,
            }
        },
        else => return error.UnexpectedResult,
    }
}

test "functionTool creates a tool definition" {
    const tool = functionTool("get_weather", "Get weather", null);
    switch (tool) {
        .function => |f| {
            try std.testing.expectEqualStrings("get_weather", f.name);
            try std.testing.expectEqualStrings("Get weather", f.description.?);
        },
    }
}
