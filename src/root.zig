/// Open Responses Zig library.
///
/// Types, JSON serialization/deserialization, SSE parsing, and HTTP
/// client for the Open Responses specification.
const std = @import("std");

pub const types = @import("types.zig");
pub const sse = @import("sse.zig");
pub const client = @import("client.zig");

test {
    _ = types;
    _ = sse;
    _ = client;
}
