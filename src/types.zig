/// Open Responses API types.
///
/// Based on the Open Responses specification (OpenAPI 3.1.0).
/// Covers core types for request/response, items, content parts,
/// function tools, and streaming events (tiers 1-3).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Parse a discriminated union from a JSON Value by inspecting a "type" field.
/// The union field names must exactly match the JSON type discriminator values.
/// Use `@"dotted.name"` syntax for values with dots (e.g. streaming events).
/// Each variant payload struct should NOT have a "type" field — it will be
/// ignored via ignore_unknown_fields.
fn parseDiscriminatedUnion(
    comptime T: type,
    allocator: Allocator,
    source: json.Value,
    options: json.ParseOptions,
) json.ParseFromValueError!T {
    if (source != .object) return error.UnexpectedToken;

    const type_val = source.object.get("type") orelse return error.UnexpectedToken;
    if (type_val != .string) return error.UnexpectedToken;
    const type_str = type_val.string;

    var child_options = options;
    child_options.ignore_unknown_fields = true;

    const fields = @typeInfo(T).@"union".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, type_str)) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            }
            return @unionInit(T, field.name, try json.parseFromValueLeaky(field.type, allocator, source, child_options));
        }
    }

    return error.UnexpectedToken;
}

/// Write struct fields to an already-open JSON object.
fn stringifyStructFields(payload: anytype, jws: anytype) !void {
    const PayloadType = @TypeOf(payload);
    const payload_info = @typeInfo(PayloadType).@"struct";
    inline for (payload_info.fields) |f| {
        if (f.type == void) continue;
        const val = @field(payload, f.name);

        var emit = true;
        if (@typeInfo(f.type) == .optional) {
            if (val == null) emit = false;
        }

        if (emit) {
            try jws.objectField(f.name);
            try jws.write(val);
        }
    }
}

/// Parse a string-or-array union from a JSON Value.
/// Returns .string for JSON strings, .parts for JSON arrays (parsed as []const ElemType).
fn parseStringOrArray(
    comptime ElemType: type,
    comptime T: type,
    allocator: Allocator,
    source: json.Value,
    options: json.ParseOptions,
) json.ParseFromValueError!T {
    return switch (source) {
        .string => |s| .{ .string = s },
        .array => .{ .parts = try json.parseFromValueLeaky([]const ElemType, allocator, source, options) },
        else => error.UnexpectedToken,
    };
}

/// Serialize a string-or-array union to JSON.
fn stringifyStringOrArray(self: anytype, jws: anytype) !void {
    switch (self) {
        .string => |s| try jws.write(s),
        .parts => |p| try jws.write(p),
    }
}

/// Serialize a discriminated union to JSON as a flat object with a "type" field.
/// The union field name is emitted as the "type" value.
/// All variant payloads must be structs (not nested unions).
fn stringifyDiscriminatedUnion(
    comptime T: type,
    self: T,
    jws: anytype,
) !void {
    switch (self) {
        inline else => |payload, tag| {
            const field_name = @tagName(tag);
            try jws.beginObject();
            try jws.objectField("type");
            try jws.write(field_name);

            const PayloadType = @TypeOf(payload);
            if (PayloadType != void) {
                try stringifyStructFields(payload, jws);
            }

            try jws.endObject();
        },
    }
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

pub const ResponseStatus = enum {
    queued,
    in_progress,
    completed,
    failed,
    incomplete,
};

pub const ItemStatus = enum {
    in_progress,
    completed,
    incomplete,
};

pub const MessageRole = enum {
    unknown,
    user,
    assistant,
    system,
    critic,
    discriminator,
    developer,
    tool,
};

pub const TruncationStrategy = enum {
    auto,
    disabled,
};

pub const ServiceTier = enum {
    auto,
    default,
    flex,
    priority,
};

pub const ToolChoiceValue = enum {
    auto,
    none,
    required,
};

pub const ImageDetail = enum {
    high,
    low,
    auto,
};

pub const ReasoningEffort = enum {
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ReasoningSummaryStyle = enum {
    auto,
    concise,
    detailed,
};

// ---------------------------------------------------------------------------
// Content parts — input
// ---------------------------------------------------------------------------

pub const InputTextContent = struct {
    text: []const u8,
};

pub const InputImageContent = struct {
    image_url: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
    detail: ImageDetail = .auto,
};

pub const InputFileContent = struct {
    file_id: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    file_url: ?[]const u8 = null,
};

pub const InputContent = union(enum) {
    input_text: InputTextContent,
    input_image: InputImageContent,
    input_file: InputFileContent,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseDiscriminatedUnion(@This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyDiscriminatedUnion(@This(), self, jws);
    }
};

// ---------------------------------------------------------------------------
// Content parts — output
// ---------------------------------------------------------------------------

pub const Annotation = struct {
    type: []const u8,
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    start_index: ?i64 = null,
    end_index: ?i64 = null,
    file_id: ?[]const u8 = null,
    filename: ?[]const u8 = null,
};

pub const TopLogProb = struct {
    token: []const u8,
    logprob: f64,
    bytes: ?[]const u8 = null,
};

pub const LogProb = struct {
    token: []const u8,
    logprob: f64,
    bytes: ?[]const u8 = null,
    top_logprobs: ?[]const TopLogProb = null,
};

pub const OutputTextContent = struct {
    text: []const u8,
    annotations: ?[]const Annotation = null,
    logprobs: ?[]const LogProb = null,
};

pub const RefusalContent = struct {
    refusal: []const u8,
};

pub const OutputContent = union(enum) {
    output_text: OutputTextContent,
    refusal: RefusalContent,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseDiscriminatedUnion(@This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyDiscriminatedUnion(@This(), self, jws);
    }
};

// ---------------------------------------------------------------------------
// Content parts — all (used in output messages)
// ---------------------------------------------------------------------------

pub const TextContent = struct {
    text: []const u8,
};

pub const SummaryTextContent = struct {
    text: []const u8,
};

pub const ReasoningTextContent = struct {
    text: []const u8,
};

pub const ContentPart = union(enum) {
    input_text: InputTextContent,
    output_text: OutputTextContent,
    refusal: RefusalContent,
    input_image: InputImageContent,
    input_file: InputFileContent,
    text: TextContent,
    summary_text: SummaryTextContent,
    reasoning_text: ReasoningTextContent,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseDiscriminatedUnion(@This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyDiscriminatedUnion(@This(), self, jws);
    }
};

// ---------------------------------------------------------------------------
// Input items (ItemParam) — what you send
// ---------------------------------------------------------------------------

pub const MessageContent = union(enum) {
    string: []const u8,
    parts: []const InputContent,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseStringOrArray(InputContent, @This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyStringOrArray(self, jws);
    }
};

pub const OutputContentOrString = union(enum) {
    string: []const u8,
    parts: []const OutputContent,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseStringOrArray(OutputContent, @This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyStringOrArray(self, jws);
    }
};

pub const FunctionCallOutputContent = union(enum) {
    string: []const u8,
    parts: []const InputContent,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseStringOrArray(InputContent, @This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyStringOrArray(self, jws);
    }
};

/// Message item param for user, system, and developer roles.
/// These share the same shape — only the role value differs.
pub const InputMessageItemParam = struct {
    role: MessageRole,
    content: MessageContent,
    id: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const AssistantMessageItemParam = struct {
    role: MessageRole = .assistant,
    content: OutputContentOrString,
    id: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const FunctionCallItemParam = struct {
    call_id: []const u8,
    name: []const u8,
    arguments: []const u8,
    id: ?[]const u8 = null,
    status: ?ItemStatus = null,
};

pub const FunctionCallOutputItemParam = struct {
    call_id: []const u8,
    output: FunctionCallOutputContent,
    id: ?[]const u8 = null,
    status: ?ItemStatus = null,
};

pub const ItemReferenceParam = struct {
    id: []const u8,
};

pub const SummaryEntry = struct {
    type: []const u8,
    text: []const u8,
};

pub const ReasoningItemParam = struct {
    summary: ?[]const SummaryEntry = null,
    id: ?[]const u8 = null,
    encrypted_content: ?[]const u8 = null,
};

/// Core input item union — what you send in a request.
///
/// Discriminated on "type" field, with messages further discriminated on "role".
pub const ItemParam = union(enum) {
    message: MessageItemParam,
    function_call: FunctionCallItemParam,
    function_call_output: FunctionCallOutputItemParam,
    item_reference: ItemReferenceParam,
    reasoning: ReasoningItemParam,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;

        const type_val = source.object.get("type") orelse return error.UnexpectedToken;
        if (type_val != .string) return error.UnexpectedToken;
        const type_str = type_val.string;

        var child_options = options;
        child_options.ignore_unknown_fields = true;

        if (std.mem.eql(u8, type_str, "message")) {
            // Further dispatch on role
            return .{ .message = try json.parseFromValueLeaky(MessageItemParam, allocator, source, child_options) };
        }
        if (std.mem.eql(u8, type_str, "function_call")) {
            return .{ .function_call = try json.parseFromValueLeaky(FunctionCallItemParam, allocator, source, child_options) };
        }
        if (std.mem.eql(u8, type_str, "function_call_output")) {
            return .{ .function_call_output = try json.parseFromValueLeaky(FunctionCallOutputItemParam, allocator, source, child_options) };
        }
        if (std.mem.eql(u8, type_str, "item_reference")) {
            return .{ .item_reference = try json.parseFromValueLeaky(ItemReferenceParam, allocator, source, child_options) };
        }
        if (std.mem.eql(u8, type_str, "reasoning")) {
            return .{ .reasoning = try json.parseFromValueLeaky(ReasoningItemParam, allocator, source, child_options) };
        }

        return error.UnexpectedToken;
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self) {
            .message => |msg| {
                try jws.beginObject();
                try jws.objectField("type");
                try jws.write("message");
                try msg.stringifyFields(jws);
                try jws.endObject();
            },
            inline else => |payload, tag| {
                try jws.beginObject();
                try jws.objectField("type");
                try jws.write(@tagName(tag));
                try stringifyStructFields(payload, jws);
                try jws.endObject();
            },
        }
    }
};

/// Message item param — sub-dispatched on "role" from ItemParam.
pub const MessageItemParam = union(enum) {
    user: InputMessageItemParam,
    system: InputMessageItemParam,
    developer: InputMessageItemParam,
    assistant: AssistantMessageItemParam,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;

        const role_val = source.object.get("role") orelse return error.UnexpectedToken;
        if (role_val != .string) return error.UnexpectedToken;
        const role_str = role_val.string;

        var child_options = options;
        child_options.ignore_unknown_fields = true;

        if (std.mem.eql(u8, role_str, "user")) {
            return .{ .user = try json.parseFromValueLeaky(InputMessageItemParam, allocator, source, child_options) };
        }
        if (std.mem.eql(u8, role_str, "system")) {
            return .{ .system = try json.parseFromValueLeaky(InputMessageItemParam, allocator, source, child_options) };
        }
        if (std.mem.eql(u8, role_str, "developer")) {
            return .{ .developer = try json.parseFromValueLeaky(InputMessageItemParam, allocator, source, child_options) };
        }
        if (std.mem.eql(u8, role_str, "assistant")) {
            return .{ .assistant = try json.parseFromValueLeaky(AssistantMessageItemParam, allocator, source, child_options) };
        }

        return error.UnexpectedToken;
    }

    pub fn stringifyFields(self: @This(), jws: anytype) !void {
        switch (self) {
            inline else => |msg| {
                try stringifyStructFields(msg, jws);
            },
        }
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write("message");
        try self.stringifyFields(jws);
        try jws.endObject();
    }
};

// ---------------------------------------------------------------------------
// Output items (ItemField) — what the model returns
// ---------------------------------------------------------------------------

pub const MessageItem = struct {
    id: []const u8,
    status: ItemStatus,
    role: MessageRole,
    content: []const ContentPart,
};

pub const FunctionCallItem = struct {
    id: []const u8,
    call_id: []const u8,
    name: []const u8,
    arguments: []const u8,
    status: ItemStatus,
    created_by: ?[]const u8 = null,
};

pub const FunctionCallOutputItem = struct {
    id: []const u8,
    call_id: []const u8,
    output: []const u8,
    status: ItemStatus,
};

pub const ReasoningItem = struct {
    id: []const u8,
    summary: ?[]const SummaryEntry = null,
    content: ?[]const json.Value = null,
    encrypted_content: ?[]const u8 = null,
};

/// Core output item union — what the model returns in a response.
pub const ItemField = union(enum) {
    message: MessageItem,
    function_call: FunctionCallItem,
    function_call_output: FunctionCallOutputItem,
    reasoning: ReasoningItem,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseDiscriminatedUnion(@This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyDiscriminatedUnion(@This(), self, jws);
    }
};

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub const FunctionTool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?json.Value = null,
    strict: ?bool = null,
};

/// Tool definition union.
pub const Tool = union(enum) {
    function: FunctionTool,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return parseDiscriminatedUnion(@This(), allocator, source, options);
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        return stringifyDiscriminatedUnion(@This(), self, jws);
    }
};

pub const SpecificToolChoice = struct {
    type: []const u8,
    name: ?[]const u8 = null,
};

/// Tool choice: either a string value ("auto", "none", "required") or a specific tool choice object.
pub const ToolChoice = union(enum) {
    auto: void,
    none: void,
    required: void,
    specific: SpecificToolChoice,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        switch (source) {
            .string => |s| {
                if (std.mem.eql(u8, s, "auto")) return .auto;
                if (std.mem.eql(u8, s, "none")) return .none;
                if (std.mem.eql(u8, s, "required")) return .required;
                return error.InvalidEnumTag;
            },
            .object => {
                var child_options = options;
                child_options.ignore_unknown_fields = true;
                return .{ .specific = try json.parseFromValueLeaky(SpecificToolChoice, allocator, source, child_options) };
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self) {
            .auto => try jws.write("auto"),
            .none => try jws.write("none"),
            .required => try jws.write("required"),
            .specific => |s| try jws.write(s),
        }
    }
};

// ---------------------------------------------------------------------------
// Request body
// ---------------------------------------------------------------------------

pub const ReasoningParam = struct {
    effort: ?ReasoningEffort = null,
    summary: ?ReasoningSummaryStyle = null,
};

pub const TextFormatType = enum {
    text,
    json_object,
    json_schema,
};

pub const TextFormat = struct {
    type: TextFormatType = .text,
    name: ?[]const u8 = null,
    schema: ?json.Value = null,
    strict: ?bool = null,
    description: ?[]const u8 = null,
};

pub const TextParam = struct {
    format: ?TextFormat = null,
};

/// Input to a request — either a string (user message) or an array of items.
pub const Input = union(enum) {
    string: []const u8,
    items: []const ItemParam,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        return switch (source) {
            .string => |s| .{ .string = s },
            .array => .{ .items = try json.parseFromValueLeaky([]const ItemParam, allocator, source, options) },
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self) {
            .string => |s| try jws.write(s),
            .items => |items| try jws.write(items),
        }
    }
};

pub const StreamOptionsParam = struct {
    include_obfuscation: ?bool = null,
};

pub const CreateResponseBody = struct {
    model: ?[]const u8 = null,
    input: ?Input = null,
    stream: ?bool = null,
    tools: ?[]const Tool = null,
    tool_choice: ?ToolChoice = null,
    instructions: ?[]const u8 = null,
    max_output_tokens: ?i64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    previous_response_id: ?[]const u8 = null,
    parallel_tool_calls: ?bool = null,
    max_tool_calls: ?i64 = null,
    reasoning: ?ReasoningParam = null,
    frequency_penalty: ?f64 = null,
    presence_penalty: ?f64 = null,
    store: ?bool = null,
    background: ?bool = null,
    metadata: ?json.Value = null,
    truncation: ?TruncationStrategy = null,
    service_tier: ?ServiceTier = null,
    text: ?TextParam = null,
    top_logprobs: ?i64 = null,
    user: ?[]const u8 = null,
    include: ?[]const []const u8 = null,
    stream_options: ?StreamOptionsParam = null,
    safety_identifier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    conversation: ?json.Value = null,
};

// ---------------------------------------------------------------------------
// Response body
// ---------------------------------------------------------------------------

pub const InputTokensDetails = struct {
    cached_tokens: i64 = 0,
};

pub const OutputTokensDetails = struct {
    reasoning_tokens: i64 = 0,
};

pub const Usage = struct {
    input_tokens: i64,
    output_tokens: i64,
    total_tokens: i64,
    input_tokens_details: ?InputTokensDetails = null,
    output_tokens_details: ?OutputTokensDetails = null,
};

pub const ResponseError = struct {
    code: []const u8,
    message: []const u8,
};

pub const IncompleteDetails = struct {
    reason: []const u8,
};

pub const ResponseResource = struct {
    id: []const u8,
    object: []const u8 = "response",
    created_at: i64,
    completed_at: ?i64 = null,
    status: ResponseStatus,
    model: []const u8,

    output: []const ItemField,
    @"error": ?ResponseError = null,
    usage: ?Usage = null,
    incomplete_details: ?IncompleteDetails = null,

    input: ?[]const ItemField = null,

    previous_response_id: ?[]const u8 = null,
    instructions: ?[]const u8 = null,

    tools: ?[]const json.Value = null,
    tool_choice: ?ToolChoice = null,
    truncation: ?TruncationStrategy = null,
    parallel_tool_calls: ?bool = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    presence_penalty: ?f64 = null,
    frequency_penalty: ?f64 = null,
    top_logprobs: ?i64 = null,
    max_output_tokens: ?i64 = null,
    max_tool_calls: ?i64 = null,
    reasoning: ?json.Value = null,
    text: ?json.Value = null,
    store: ?bool = null,
    background: ?bool = null,
    service_tier: ?[]const u8 = null,
    metadata: ?json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    conversation: ?json.Value = null,
    next_response_ids: ?[]const []const u8 = null,
};

// ---------------------------------------------------------------------------
// Error payload
// ---------------------------------------------------------------------------

pub const ErrorPayload = struct {
    type: []const u8 = "error",
    code: ?[]const u8 = null,
    message: []const u8,
    param: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Streaming events
// ---------------------------------------------------------------------------

pub const ResponseOutputTextDeltaEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    delta: []const u8,
    logprobs: ?[]const LogProb = null,
    obfuscation: ?[]const u8 = null,
};

pub const ResponseCompletedEvent = struct {
    sequence_number: i64,
    response: ResponseResource,
};

pub const ResponseFailedEvent = struct {
    sequence_number: i64,
    response: ResponseResource,
};

pub const ErrorEvent = struct {
    sequence_number: i64,
    @"error": ErrorPayload,
};

pub const ResponseOutputItemAddedEvent = struct {
    sequence_number: i64,
    output_index: i64,
    item: ?json.Value = null,
};

pub const ResponseOutputItemDoneEvent = struct {
    sequence_number: i64,
    output_index: i64,
    item: ?json.Value = null,
};

pub const ResponseFunctionCallArgumentsDeltaEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    delta: []const u8,
};

pub const ResponseFunctionCallArgumentsDoneEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    arguments: []const u8,
};

pub const ResponseCreatedEvent = struct {
    sequence_number: i64,
    response: ResponseResource,
};

pub const ResponseInProgressEvent = struct {
    sequence_number: i64,
    response: ResponseResource,
};

pub const ResponseIncompleteEvent = struct {
    sequence_number: i64,
    response: ResponseResource,
};

pub const ResponseOutputTextDoneEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    text: []const u8,
    logprobs: ?[]const LogProb = null,
};

pub const ResponseContentPartAddedEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    part: ?ContentPart = null,
};

pub const ResponseContentPartDoneEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    part: ?ContentPart = null,
};

pub const ResponseQueuedEvent = struct {
    sequence_number: i64,
    response: ResponseResource,
};

pub const ResponseRefusalDeltaEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    delta: []const u8,
};

pub const ResponseRefusalDoneEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    refusal: []const u8,
};

pub const ResponseReasoningDeltaEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    delta: []const u8,
    obfuscation: ?[]const u8 = null,
};

pub const ResponseReasoningDoneEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    text: []const u8,
};

pub const ResponseReasoningSummaryPartAddedEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    summary_index: i64,
    part: ?json.Value = null,
};

pub const ResponseReasoningSummaryPartDoneEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    summary_index: i64,
    part: ?json.Value = null,
};

pub const ResponseReasoningSummaryTextDeltaEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    summary_index: i64,
    delta: []const u8,
    obfuscation: ?[]const u8 = null,
};

pub const ResponseReasoningSummaryTextDoneEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    summary_index: i64,
    text: []const u8,
};

pub const ResponseOutputTextAnnotationAddedEvent = struct {
    sequence_number: i64,
    item_id: []const u8,
    output_index: i64,
    content_index: i64,
    annotation_index: i64,
    annotation: ?json.Value = null,
};

/// Union of all recognized streaming event types.
pub const StreamingEvent = union(enum) {
    // Tier 1 — must handle
    @"response.output_text.delta": ResponseOutputTextDeltaEvent,
    @"response.completed": ResponseCompletedEvent,
    @"response.failed": ResponseFailedEvent,
    @"error": ErrorEvent,

    // Tier 2 — needed for tool calling
    @"response.output_item.added": ResponseOutputItemAddedEvent,
    @"response.output_item.done": ResponseOutputItemDoneEvent,
    @"response.function_call_arguments.delta": ResponseFunctionCallArgumentsDeltaEvent,
    @"response.function_call_arguments.done": ResponseFunctionCallArgumentsDoneEvent,

    // Tier 3 — lifecycle, content, reasoning, refusal, annotations
    @"response.created": ResponseCreatedEvent,
    @"response.queued": ResponseQueuedEvent,
    @"response.in_progress": ResponseInProgressEvent,
    @"response.incomplete": ResponseIncompleteEvent,
    @"response.output_text.done": ResponseOutputTextDoneEvent,
    @"response.content_part.added": ResponseContentPartAddedEvent,
    @"response.content_part.done": ResponseContentPartDoneEvent,
    @"response.refusal.delta": ResponseRefusalDeltaEvent,
    @"response.refusal.done": ResponseRefusalDoneEvent,
    @"response.reasoning.delta": ResponseReasoningDeltaEvent,
    @"response.reasoning.done": ResponseReasoningDoneEvent,
    @"response.reasoning_summary_part.added": ResponseReasoningSummaryPartAddedEvent,
    @"response.reasoning_summary_part.done": ResponseReasoningSummaryPartDoneEvent,
    @"response.reasoning_summary_text.delta": ResponseReasoningSummaryTextDeltaEvent,
    @"response.reasoning_summary_text.done": ResponseReasoningSummaryTextDoneEvent,
    @"response.output_text.annotation.added": ResponseOutputTextAnnotationAddedEvent,

    /// Catch-all for event types not yet modeled (the spec defines 50+).
    /// Preserves the full JSON value so callers can inspect it.
    unknown: json.Value,

    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;

        const type_val = source.object.get("type") orelse return error.UnexpectedToken;
        if (type_val != .string) return error.UnexpectedToken;
        const type_str = type_val.string;

        var child_options = options;
        child_options.ignore_unknown_fields = true;

        const fields = @typeInfo(@This()).@"union".fields;
        inline for (fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "unknown")) continue;
            if (std.mem.eql(u8, field.name, type_str)) {
                return @unionInit(@This(), field.name, try json.parseFromValueLeaky(field.type, allocator, source, child_options));
            }
        }

        return .{ .unknown = source };
    }

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self) {
            .unknown => |val| try jws.write(val),
            else => return stringifyDiscriminatedUnion(@This(), self, jws),
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn parseJsonValue(allocator: Allocator, input: []const u8) !json.Value {
    return try json.parseFromSliceLeaky(json.Value, allocator, input, .{});
}

test "union field names match JSON type discriminators" {
    // Verify that our union field names are the exact JSON type values.
    // StreamingEvent uses @"dotted.name" syntax for dotted type values.
    const se_fields = @typeInfo(StreamingEvent).@"union".fields;
    try testing.expectEqualStrings("response.output_text.delta", se_fields[0].name);
    try testing.expectEqualStrings("response.completed", se_fields[1].name);

    // InputContent uses plain underscore names matching JSON
    const ic_fields = @typeInfo(InputContent).@"union".fields;
    try testing.expectEqualStrings("input_text", ic_fields[0].name);
    try testing.expectEqualStrings("input_image", ic_fields[1].name);
}

test "ResponseStatus round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc, "\"in_progress\"");
    const status = try json.parseFromValueLeaky(ResponseStatus, alloc, val, .{});
    try testing.expectEqual(ResponseStatus.in_progress, status);
}

test "InputContent discriminated union parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "input_text", "text": "hello"}
    );
    const content = try json.parseFromValueLeaky(InputContent, alloc, val, .{});
    switch (content) {
        .input_text => |t| try testing.expectEqualStrings("hello", t.text),
        else => return error.UnexpectedToken,
    }
}

test "ItemParam message with role dispatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "message", "role": "user", "content": "hello world"}
    );
    const item = try json.parseFromValueLeaky(ItemParam, alloc, val, .{});
    switch (item) {
        .message => |msg| {
            switch (msg) {
                .user => |u| {
                    switch (u.content) {
                        .string => |s| try testing.expectEqualStrings("hello world", s),
                        else => return error.UnexpectedToken,
                    }
                },
                else => return error.UnexpectedToken,
            }
        },
        else => return error.UnexpectedToken,
    }
}

test "ItemParam function_call parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "function_call", "call_id": "call_1", "name": "get_weather", "arguments": "{\"city\": \"SF\"}"}
    );
    const item = try json.parseFromValueLeaky(ItemParam, alloc, val, .{});
    switch (item) {
        .function_call => |fc| {
            try testing.expectEqualStrings("call_1", fc.call_id);
            try testing.expectEqualStrings("get_weather", fc.name);
        },
        else => return error.UnexpectedToken,
    }
}

test "Annotation parse with url_citation fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "output_text", "text": "See source.", "annotations": [{"type": "url_citation", "url": "https://example.com", "title": "Example", "start_index": 4, "end_index": 10}]}
    );
    const part = try json.parseFromValueLeaky(ContentPart, alloc, val, .{ .ignore_unknown_fields = true });
    switch (part) {
        .output_text => |t| {
            try testing.expectEqualStrings("See source.", t.text);
            try testing.expect(t.annotations != null);
            try testing.expect(t.annotations.?.len == 1);
            const ann = t.annotations.?[0];
            try testing.expectEqualStrings("url_citation", ann.type);
            try testing.expectEqualStrings("https://example.com", ann.url.?);
            try testing.expectEqualStrings("Example", ann.title.?);
            try testing.expectEqual(@as(i64, 4), ann.start_index.?);
            try testing.expectEqual(@as(i64, 10), ann.end_index.?);
        },
        else => return error.UnexpectedToken,
    }
}

test "LogProb with top_logprobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "output_text", "text": "Hi", "logprobs": [{"token": "Hi", "logprob": -0.5, "top_logprobs": [{"token": "Hi", "logprob": -0.5}, {"token": "Hello", "logprob": -1.2}]}]}
    );
    const part = try json.parseFromValueLeaky(ContentPart, alloc, val, .{ .ignore_unknown_fields = true });
    switch (part) {
        .output_text => |t| {
            try testing.expect(t.logprobs != null);
            try testing.expect(t.logprobs.?.len == 1);
            const lp = t.logprobs.?[0];
            try testing.expectEqualStrings("Hi", lp.token);
            try testing.expect(lp.top_logprobs != null);
            try testing.expect(lp.top_logprobs.?.len == 2);
            try testing.expectEqualStrings("Hello", lp.top_logprobs.?[1].token);
        },
        else => return error.UnexpectedToken,
    }
}

test "ItemField output message parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "message", "id": "msg_1", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": "Hello!"}]}
    );
    const item = try json.parseFromValueLeaky(ItemField, alloc, val, .{});
    switch (item) {
        .message => |msg| {
            try testing.expectEqualStrings("msg_1", msg.id);
            try testing.expectEqual(ItemStatus.completed, msg.status);
            try testing.expectEqual(MessageRole.assistant, msg.role);
            try testing.expect(msg.content.len == 1);
            switch (msg.content[0]) {
                .output_text => |t| try testing.expectEqualStrings("Hello!", t.text),
                else => return error.UnexpectedToken,
            }
        },
        else => return error.UnexpectedToken,
    }
}

test "ReasoningItem parse with encrypted_content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "reasoning", "id": "rs_1", "summary": [{"type": "summary_text", "text": "Thinking..."}], "encrypted_content": "abc123opaque"}
    );
    const item = try json.parseFromValueLeaky(ItemField, alloc, val, .{ .ignore_unknown_fields = true });
    switch (item) {
        .reasoning => |r| {
            try testing.expectEqualStrings("rs_1", r.id);
            try testing.expect(r.summary != null);
            try testing.expect(r.summary.?.len == 1);
            try testing.expectEqualStrings("abc123opaque", r.encrypted_content.?);
        },
        else => return error.UnexpectedToken,
    }
}

test "ToolChoice string and object variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // String variant
    const auto_val = try parseJsonValue(alloc, "\"auto\"");
    const auto_choice = try json.parseFromValueLeaky(ToolChoice, alloc, auto_val, .{});
    try testing.expectEqual(ToolChoice.auto, auto_choice);

    // Object variant
    const obj_val = try parseJsonValue(alloc,
        \\{"type": "function", "name": "get_weather"}
    );
    const obj_choice = try json.parseFromValueLeaky(ToolChoice, alloc, obj_val, .{});
    switch (obj_choice) {
        .specific => |s| {
            try testing.expectEqualStrings("function", s.type);
            try testing.expectEqualStrings("get_weather", s.name.?);
        },
        else => return error.UnexpectedToken,
    }
}

test "StreamingEvent text delta parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "response.output_text.delta", "sequence_number": 5, "item_id": "item_1", "output_index": 0, "content_index": 0, "delta": "Hello"}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .@"response.output_text.delta" => |e| {
            try testing.expectEqual(@as(i64, 5), e.sequence_number);
            try testing.expectEqualStrings("Hello", e.delta);
            try testing.expectEqualStrings("item_1", e.item_id);
        },
        else => return error.UnexpectedToken,
    }
}

test "StreamingEvent response.completed parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "response.completed", "sequence_number": 10, "response": {"id": "resp_1", "object": "response", "created_at": 1234567890, "status": "completed", "model": "gpt-4", "output": [{"type": "message", "id": "msg_1", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": "Hi!"}]}]}}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .@"response.completed" => |e| {
            try testing.expectEqual(@as(i64, 10), e.sequence_number);
            try testing.expectEqualStrings("resp_1", e.response.id);
            try testing.expectEqual(ResponseStatus.completed, e.response.status);
            try testing.expect(e.response.output.len == 1);
        },
        else => return error.UnexpectedToken,
    }
}

test "StreamingEvent text delta with logprobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "response.output_text.delta", "sequence_number": 3, "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": "Hi", "logprobs": [{"token": "Hi", "logprob": -0.5}], "obfuscation": "masked"}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .@"response.output_text.delta" => |e| {
            try testing.expectEqualStrings("Hi", e.delta);
            try testing.expect(e.logprobs != null);
            try testing.expect(e.logprobs.?.len == 1);
            try testing.expectEqualStrings("Hi", e.logprobs.?[0].token);
            try testing.expectEqualStrings("masked", e.obfuscation.?);
        },
        else => return error.UnexpectedToken,
    }
}

test "StreamingEvent content_part.added with typed ContentPart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "response.content_part.added", "sequence_number": 4, "item_id": "msg_1", "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .@"response.content_part.added" => |e| {
            try testing.expectEqual(@as(i64, 4), e.sequence_number);
            try testing.expect(e.part != null);
            switch (e.part.?) {
                .output_text => |t| try testing.expectEqualStrings("", t.text),
                else => return error.UnexpectedToken,
            }
        },
        else => return error.UnexpectedToken,
    }
}

test "CreateResponseBody serialization omits null fields" {
    const body = CreateResponseBody{
        .model = "gpt-4",
        .input = .{ .string = "Hello" },
        .stream = true,
    };

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var jws: json.Stringify = .{ .writer = &writer, .options = .{
        .emit_null_optional_fields = false,
    } };
    try jws.write(body);

    const output = writer.buffered();

    // Should contain the set fields
    try testing.expect(std.mem.indexOf(u8, output, "\"model\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"gpt-4\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"stream\"") != null);

    // Should NOT contain null fields
    try testing.expect(std.mem.indexOf(u8, output, "\"tools\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"instructions\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"temperature\"") == null);
}

test "Tool function parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "function", "name": "get_weather", "description": "Get weather for a city", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}}}
    );
    const tool = try json.parseFromValueLeaky(Tool, alloc, val, .{});
    switch (tool) {
        .function => |f| {
            try testing.expectEqualStrings("get_weather", f.name);
            try testing.expectEqualStrings("Get weather for a city", f.description.?);
            try testing.expect(f.parameters != null);
        },
    }
}

test "ResponseResource full parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input =
        \\{
        \\  "id": "resp_123",
        \\  "object": "response",
        \\  "created_at": 1700000000,
        \\  "completed_at": 1700000005,
        \\  "status": "completed",
        \\  "model": "gpt-4",
        \\  "output": [
        \\    {
        \\      "type": "message",
        \\      "id": "msg_1",
        \\      "status": "completed",
        \\      "role": "assistant",
        \\      "content": [{"type": "output_text", "text": "Hello!"}]
        \\    }
        \\  ],
        \\  "error": null,
        \\  "usage": {
        \\    "input_tokens": 10,
        \\    "output_tokens": 5,
        \\    "total_tokens": 15
        \\  },
        \\  "temperature": 0.7,
        \\  "top_p": 1.0,
        \\  "store": false
        \\}
    ;

    const val = try parseJsonValue(alloc, input);
    const resp = try json.parseFromValueLeaky(ResponseResource, alloc, val, .{ .ignore_unknown_fields = true });

    try testing.expectEqualStrings("resp_123", resp.id);
    try testing.expectEqual(ResponseStatus.completed, resp.status);
    try testing.expectEqualStrings("gpt-4", resp.model);
    try testing.expect(resp.output.len == 1);
    try testing.expectEqual(@as(i64, 1700000005), resp.completed_at.?);
    try testing.expectEqual(@as(i64, 10), resp.usage.?.input_tokens);
}

test "CreateResponseBody serialization with new fields" {
    const body = CreateResponseBody{
        .model = "gpt-4",
        .input = .{ .string = "Hello" },
        .include = &.{ "reasoning.encrypted_content", "message.output_text.logprobs" },
        .stream_options = .{ .include_obfuscation = true },
        .safety_identifier = "user-abc",
        .prompt_cache_key = "cache-key-1",
    };

    var ser_buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&ser_buf);
    var jws: json.Stringify = .{ .writer = &writer, .options = .{ .emit_null_optional_fields = false } };
    try jws.write(body);
    const output = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, output, "\"include\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"reasoning.encrypted_content\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"stream_options\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"include_obfuscation\":true") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"safety_identifier\":\"user-abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"prompt_cache_key\":\"cache-key-1\"") != null);
}

test "ResponseResource parse with new fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input =
        \\{
        \\  "id": "resp_456",
        \\  "object": "response",
        \\  "created_at": 1700000000,
        \\  "status": "completed",
        \\  "model": "gpt-4",
        \\  "output": [],
        \\  "safety_identifier": "user-xyz",
        \\  "prompt_cache_key": "pk_123",
        \\  "conversation": {"id": "conv_1"},
        \\  "next_response_ids": ["resp_789", "resp_790"]
        \\}
    ;

    const val = try parseJsonValue(alloc, input);
    const resp = try json.parseFromValueLeaky(ResponseResource, alloc, val, .{ .ignore_unknown_fields = true });

    try testing.expectEqualStrings("resp_456", resp.id);
    try testing.expectEqualStrings("user-xyz", resp.safety_identifier.?);
    try testing.expectEqualStrings("pk_123", resp.prompt_cache_key.?);
    try testing.expect(resp.conversation != null);
    try testing.expect(resp.next_response_ids != null);
    try testing.expect(resp.next_response_ids.?.len == 2);
    try testing.expectEqualStrings("resp_789", resp.next_response_ids.?[0]);
    try testing.expectEqualStrings("resp_790", resp.next_response_ids.?[1]);
}

test "StreamingEvent response.queued parses to typed variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "response.queued", "sequence_number": 0, "response": {"id": "r1", "object": "response", "created_at": 0, "status": "queued", "model": "m", "output": []}}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .@"response.queued" => |e| {
            try testing.expectEqual(@as(i64, 0), e.sequence_number);
            try testing.expectEqualStrings("r1", e.response.id);
            try testing.expectEqual(ResponseStatus.queued, e.response.status);
        },
        else => return error.UnexpectedToken,
    }
}

test "StreamingEvent unknown type falls through to unknown variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "provider.custom_event", "sequence_number": 0, "data": "test"}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .unknown => |v| {
            try testing.expect(v == .object);
            const type_str = v.object.get("type").?.string;
            try testing.expectEqualStrings("provider.custom_event", type_str);
        },
        else => return error.UnexpectedToken,
    }
}

test "StreamingEvent refusal delta parses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "response.refusal.delta", "sequence_number": 2, "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": "I cannot"}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .@"response.refusal.delta" => |e| {
            try testing.expectEqualStrings("I cannot", e.delta);
            try testing.expectEqualStrings("msg_1", e.item_id);
        },
        else => return error.UnexpectedToken,
    }
}

test "StreamingEvent reasoning delta with obfuscation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try parseJsonValue(alloc,
        \\{"type": "response.reasoning.delta", "sequence_number": 1, "item_id": "rs_1", "output_index": 0, "content_index": 0, "delta": "Let me think", "obfuscation": "hidden"}
    );
    const event = try json.parseFromValueLeaky(StreamingEvent, alloc, val, .{});
    switch (event) {
        .@"response.reasoning.delta" => |e| {
            try testing.expectEqualStrings("Let me think", e.delta);
            try testing.expectEqualStrings("hidden", e.obfuscation.?);
        },
        else => return error.UnexpectedToken,
    }
}
