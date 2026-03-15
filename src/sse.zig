/// Server-Sent Events (SSE) parser for Open Responses streaming.
///
/// Reads SSE events from an `std.Io.Reader`, assembling `event:` and `data:`
/// field pairs, and optionally parsing JSON data into typed `StreamingEvent`s.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const types = @import("types.zig");

/// A raw SSE event — event type string + data string, before JSON parsing.
pub const SseEvent = struct {
    event_type: []const u8,
    data: []const u8,
};

/// Reports a gap or reordering in the SSE sequence_number stream.
/// Observational only — events are never dropped.
pub const SequenceAnomaly = struct {
    type: enum { gap, out_of_order },
    expected: i64,
    received: i64,
};

/// Callback type for sequence anomaly notifications.
pub const OnSequenceAnomaly = *const fn (anomaly: SequenceAnomaly) void;

/// Extracts `sequence_number` from a typed StreamingEvent.
/// Returns null for the `unknown` variant if the field is absent.
pub fn sequenceNumber(event: types.StreamingEvent) ?i64 {
    switch (event) {
        .unknown => |val| {
            if (val == .object) {
                if (val.object.get("sequence_number")) |sn| {
                    if (sn == .integer) return sn.integer;
                }
            }
            return null;
        },
        inline else => |payload| return payload.sequence_number,
    }
}

/// SSE parser iterator. Reads from an `*Io.Reader` and yields events.
///
/// SSE format:
///   event: <type>\n
///   data: <json>\n
///   \n                  (blank line = event boundary)
///
/// The `[DONE]` sentinel in the data field signals end-of-stream.
/// SSE parser iterator. Reads from an `*Io.Reader` and yields events.
///
/// Event data (`event_type`, `data`) is valid until the next `next()` call.
pub const SseParser = struct {
    reader: *Reader,
    allocator: Allocator,
    done: bool = false,

    event_type_buf: std.ArrayList(u8),
    data_buf: std.ArrayList(u8),

    last_seq: i64 = -1,
    on_anomaly: ?OnSequenceAnomaly = null,

    pub fn init(allocator: Allocator, reader: *Reader) SseParser {
        return .{
            .reader = reader,
            .allocator = allocator,
            .event_type_buf = .empty,
            .data_buf = .empty,
        };
    }

    pub fn initWithValidation(allocator: Allocator, reader: *Reader, on_anomaly: OnSequenceAnomaly) SseParser {
        var parser = init(allocator, reader);
        parser.on_anomaly = on_anomaly;
        return parser;
    }

    pub fn deinit(self: *SseParser) void {
        self.event_type_buf.deinit(self.allocator);
        self.data_buf.deinit(self.allocator);
    }

    /// Return the next raw SSE event, or null at end-of-stream.
    /// The returned slices are valid until the next call to `next()`.
    pub fn next(self: *SseParser) (Reader.DelimiterError || Allocator.Error)!?SseEvent {
        if (self.done) return null;

        // Reset state for the new event
        self.event_type_buf.clearRetainingCapacity();
        self.data_buf.clearRetainingCapacity();

        while (true) {
            const raw_line = try self.reader.takeDelimiter('\n') orelse {
                // EOF — if we have accumulated data, emit it as a final event
                if (self.data_buf.items.len > 0) {
                    self.done = true;
                    return self.buildEvent();
                }
                return null;
            };

            // Strip trailing \r for \r\n line endings
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;

            // Empty line = event boundary
            if (line.len == 0) {
                if (self.data_buf.items.len > 0) {
                    return self.buildEvent();
                }
                // Empty event, keep reading
                continue;
            }

            // Skip comment lines (start with ':')
            if (line[0] == ':') continue;

            // Parse "field: value" or "field:value" or "field"
            if (std.mem.indexOfScalar(u8, line, ':')) |colon_pos| {
                const field = line[0..colon_pos];
                var value = line[colon_pos + 1 ..];
                // Strip leading space after colon (SSE spec)
                if (value.len > 0 and value[0] == ' ') {
                    value = value[1..];
                }

                if (std.mem.eql(u8, field, "event")) {
                    self.event_type_buf.clearRetainingCapacity();
                    try self.event_type_buf.appendSlice(self.allocator, value);
                } else if (std.mem.eql(u8, field, "data")) {
                    // Check for [DONE] sentinel
                    if (std.mem.eql(u8, value, "[DONE]")) {
                        self.done = true;
                        // If we have accumulated data, emit it first
                        if (self.data_buf.items.len > 0) {
                            return self.buildEvent();
                        }
                        return null;
                    }
                    // Append data (multiple data lines are joined with \n)
                    if (self.data_buf.items.len > 0) {
                        try self.data_buf.append(self.allocator, '\n');
                    }
                    try self.data_buf.appendSlice(self.allocator, value);
                }
                // Ignore other fields (id, retry, etc.)
            }
        }
    }

    fn buildEvent(self: *SseParser) SseEvent {
        return .{
            .event_type = if (self.event_type_buf.items.len > 0) self.event_type_buf.items else "",
            .data = self.data_buf.items,
        };
    }

    /// Return the next typed streaming event, or null at end-of-stream.
    /// Parses the SSE data as JSON into a `StreamingEvent`.
    /// When an anomaly callback is set, validates sequence_number ordering.
    pub fn nextEvent(self: *SseParser) !?types.StreamingEvent {
        const raw = try self.next() orelse return null;

        if (raw.data.len == 0) return error.UnexpectedToken;

        // Two-phase parse: JSON bytes -> Value -> StreamingEvent
        const value = try json.parseFromSliceLeaky(json.Value, self.allocator, raw.data, .{});
        const event = try json.parseFromValueLeaky(types.StreamingEvent, self.allocator, value, .{});

        if (self.on_anomaly) |cb| {
            if (sequenceNumber(event)) |seq| {
                if (self.last_seq >= 0) {
                    if (seq <= self.last_seq) {
                        cb(.{ .type = .out_of_order, .expected = self.last_seq + 1, .received = seq });
                    } else if (seq > self.last_seq + 1) {
                        cb(.{ .type = .gap, .expected = self.last_seq + 1, .received = seq });
                    }
                }
                if (seq > self.last_seq) {
                    self.last_seq = seq;
                }
            }
        }

        return event;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "SseParser: single text delta event" {
    const input = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"item_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}\n\n";

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(testing.allocator, &reader);
    defer parser.deinit();

    const event = try parser.next();
    try testing.expect(event != null);
    try testing.expectEqualStrings("response.output_text.delta", event.?.event_type);
    try testing.expect(std.mem.indexOf(u8, event.?.data, "\"Hello\"") != null);

    // No more events
    const end = try parser.next();
    try testing.expect(end == null);
}

test "SseParser: multi-event stream with DONE" {
    const input =
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"i1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hi\"}\n" ++
        "\n" ++
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":2,\"item_id\":\"i1\",\"output_index\":0,\"content_index\":0,\"delta\":\" there\"}\n" ++
        "\n" ++
        "data: [DONE]\n" ++
        "\n";

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(testing.allocator, &reader);
    defer parser.deinit();

    // First event
    const e1 = try parser.next();
    try testing.expect(e1 != null);
    try testing.expectEqualStrings("response.output_text.delta", e1.?.event_type);

    // Second event
    const e2 = try parser.next();
    try testing.expect(e2 != null);

    // DONE
    const e3 = try parser.next();
    try testing.expect(e3 == null);
}

test "SseParser: CRLF line endings" {
    const input = "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"i1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hi\"}\r\n\r\n";

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(testing.allocator, &reader);
    defer parser.deinit();

    const event = try parser.next();
    try testing.expect(event != null);
    try testing.expectEqualStrings("response.output_text.delta", event.?.event_type);
}

test "SseParser: comment lines are ignored" {
    const input = ": this is a comment\nevent: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"i1\",\"output_index\":0,\"content_index\":0,\"delta\":\"X\"}\n\n";

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(testing.allocator, &reader);
    defer parser.deinit();

    const event = try parser.next();
    try testing.expect(event != null);
    try testing.expectEqualStrings("response.output_text.delta", event.?.event_type);
}

test "SseParser: nextEvent typed parsing" {
    const input = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"sequence_number\":5,\"item_id\":\"item_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}\n\ndata: [DONE]\n\n";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(alloc, &reader);

    const event = try parser.nextEvent();
    try testing.expect(event != null);
    switch (event.?) {
        .@"response.output_text.delta" => |e| {
            try testing.expectEqual(@as(i64, 5), e.sequence_number);
            try testing.expectEqualStrings("Hello", e.delta);
        },
        else => return error.UnexpectedToken,
    }

    // DONE
    const end = try parser.nextEvent();
    try testing.expect(end == null);
}

test "SseParser: blank lines between events" {
    const input =
        "\n\n" ++ // Leading blank lines
        "event: response.created\n" ++
        "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"r1\",\"object\":\"response\",\"created_at\":0,\"status\":\"in_progress\",\"model\":\"m\",\"output\":[]}}\n" ++
        "\n" ++
        "\n" ++ // Extra blank line between events
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"i1\",\"output_index\":0,\"content_index\":0,\"delta\":\"X\"}\n" ++
        "\n";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(alloc, &reader);

    const e1 = try parser.nextEvent();
    try testing.expect(e1 != null);
    switch (e1.?) {
        .@"response.created" => {},
        else => return error.UnexpectedToken,
    }

    const e2 = try parser.nextEvent();
    try testing.expect(e2 != null);
    switch (e2.?) {
        .@"response.output_text.delta" => {},
        else => return error.UnexpectedToken,
    }

    const e3 = try parser.nextEvent();
    try testing.expect(e3 == null);
}

test "SseParser: event without explicit event field" {
    // Some SSE implementations don't send event: field, just data:
    const input = "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"i1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Y\"}\n\n";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(alloc, &reader);

    const raw = try parser.next();
    try testing.expect(raw != null);
    try testing.expectEqualStrings("", raw.?.event_type); // No event field -> empty string

    // Typed parsing should still work since we parse from JSON "type" field
    var reader2: Reader = .fixed(input);
    var parser2 = SseParser.init(alloc, &reader2);

    const event = try parser2.nextEvent();
    try testing.expect(event != null);
    switch (event.?) {
        .@"response.output_text.delta" => |e| {
            try testing.expectEqualStrings("Y", e.delta);
        },
        else => return error.UnexpectedToken,
    }
}

test "sequenceNumber: typed event" {
    const event: types.StreamingEvent = .{
        .@"response.output_text.delta" = .{
            .sequence_number = 42,
            .item_id = "i1",
            .output_index = 0,
            .content_index = 0,
            .delta = "x",
        },
    };
    try testing.expectEqual(@as(?i64, 42), sequenceNumber(event));
}

test "sequenceNumber: unknown event with sequence_number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.parseFromSliceLeaky(json.Value, alloc,
        \\{"type": "provider.custom", "sequence_number": 7}
    , .{});
    const event = try json.parseFromValueLeaky(types.StreamingEvent, alloc, val, .{});
    try testing.expectEqual(@as(?i64, 7), sequenceNumber(event));
}

test "sequenceNumber: unknown event without sequence_number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.parseFromSliceLeaky(json.Value, alloc,
        \\{"type": "provider.custom", "data": "hello"}
    , .{});
    const event = try json.parseFromValueLeaky(types.StreamingEvent, alloc, val, .{});
    try testing.expectEqual(@as(?i64, null), sequenceNumber(event));
}

fn buildSseStream(comptime events: []const struct { seq: i64 }) []const u8 {
    comptime {
        var buf: []const u8 = "";
        for (events) |e| {
            buf = buf ++
                "event: response.output_text.delta\n" ++
                "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":" ++
                std.fmt.comptimePrint("{d}", .{e.seq}) ++
                ",\"item_id\":\"i1\",\"output_index\":0,\"content_index\":0,\"delta\":\"x\"}\n\n";
        }
        buf = buf ++ "data: [DONE]\n\n";
        return buf;
    }
}

test "sequence validation: normal monotonic — no anomaly" {
    const input = comptime buildSseStream(&.{ .{ .seq = 0 }, .{ .seq = 1 }, .{ .seq = 2 } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const AnomalyTracker = struct {
        var count: u32 = 0;
        fn onAnomaly(_: SequenceAnomaly) void {
            count += 1;
        }
    };
    AnomalyTracker.count = 0;

    var reader: Reader = .fixed(input);
    var parser = SseParser.initWithValidation(alloc, &reader, &AnomalyTracker.onAnomaly);

    var event_count: u32 = 0;
    while (try parser.nextEvent()) |_| {
        event_count += 1;
    }
    try testing.expectEqual(@as(u32, 3), event_count);
    try testing.expectEqual(@as(u32, 0), AnomalyTracker.count);
}

test "sequence validation: gap detected" {
    const input = comptime buildSseStream(&.{ .{ .seq = 0 }, .{ .seq = 1 }, .{ .seq = 5 } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const AnomalyTracker = struct {
        var last_anomaly: ?SequenceAnomaly = null;
        var count: u32 = 0;
        fn onAnomaly(a: SequenceAnomaly) void {
            last_anomaly = a;
            count += 1;
        }
    };
    AnomalyTracker.last_anomaly = null;
    AnomalyTracker.count = 0;

    var reader: Reader = .fixed(input);
    var parser = SseParser.initWithValidation(alloc, &reader, &AnomalyTracker.onAnomaly);

    while (try parser.nextEvent()) |_| {}

    try testing.expectEqual(@as(u32, 1), AnomalyTracker.count);
    try testing.expect(AnomalyTracker.last_anomaly != null);
    try testing.expectEqual(SequenceAnomaly{ .type = .gap, .expected = 2, .received = 5 }, AnomalyTracker.last_anomaly.?);
}

test "sequence validation: out-of-order detected" {
    const input = comptime buildSseStream(&.{ .{ .seq = 0 }, .{ .seq = 1 }, .{ .seq = 3 }, .{ .seq = 2 } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const AnomalyTracker = struct {
        var anomalies: [8]SequenceAnomaly = undefined;
        var count: u32 = 0;
        fn onAnomaly(a: SequenceAnomaly) void {
            if (count < 8) {
                anomalies[count] = a;
            }
            count += 1;
        }
    };
    AnomalyTracker.count = 0;

    var reader: Reader = .fixed(input);
    var parser = SseParser.initWithValidation(alloc, &reader, &AnomalyTracker.onAnomaly);

    var event_count: u32 = 0;
    while (try parser.nextEvent()) |_| {
        event_count += 1;
    }
    try testing.expectEqual(@as(u32, 4), event_count);
    try testing.expectEqual(@as(u32, 2), AnomalyTracker.count);
    // First anomaly: gap from 1 to 3
    try testing.expectEqual(SequenceAnomaly{ .type = .gap, .expected = 2, .received = 3 }, AnomalyTracker.anomalies[0]);
    // Second anomaly: out-of-order, got 2 after seeing 3
    try testing.expectEqual(SequenceAnomaly{ .type = .out_of_order, .expected = 4, .received = 2 }, AnomalyTracker.anomalies[1]);
}

test "sequence validation: no callback — no tracking" {
    const input = comptime buildSseStream(&.{ .{ .seq = 0 }, .{ .seq = 5 } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reader: Reader = .fixed(input);
    var parser = SseParser.init(alloc, &reader);

    var event_count: u32 = 0;
    while (try parser.nextEvent()) |_| {
        event_count += 1;
    }
    try testing.expectEqual(@as(u32, 2), event_count);
}
