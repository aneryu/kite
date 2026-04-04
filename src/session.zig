const std = @import("std");

pub const RingBuffer = struct {
    data: []u8,
    head: usize = 0,
    len: usize = 0,
    allocator: std.mem.Allocator,

    pub const default_capacity = 256 * 1024; // 256KB

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        return .{
            .data = try allocator.alloc(u8, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.data);
    }

    pub fn write(self: *RingBuffer, bytes: []const u8) void {
        for (bytes) |byte| {
            self.data[(self.head + self.len) % self.data.len] = byte;
            if (self.len == self.data.len) {
                self.head = (self.head + 1) % self.data.len;
            } else {
                self.len += 1;
            }
        }
    }

    pub fn getContents(self: *const RingBuffer, out: []u8) usize {
        const to_copy = @min(self.len, out.len);
        var i: usize = 0;
        while (i < to_copy) : (i += 1) {
            out[i] = self.data[(self.head + i) % self.data.len];
        }
        return to_copy;
    }

    pub fn slice(self: *const RingBuffer) struct { first: []const u8, second: []const u8 } {
        if (self.len == 0) return .{ .first = &.{}, .second = &.{} };
        const start = self.head;
        const end = (self.head + self.len) % self.data.len;
        if (end > start) {
            return .{ .first = self.data[start..end], .second = &.{} };
        } else {
            return .{ .first = self.data[start..], .second = self.data[0..end] };
        }
    }
};

pub const SessionState = enum {
    starting,
    running,
    waiting_input,
    stopped,
};

pub const PromptContext = struct {
    summary: []const u8,
    options: []const []const u8,
    raw_json: []const u8 = "",
};

pub const HookEvent = struct {
    event_name: []const u8,
    session_id: []const u8 = "",
    tool_name: []const u8 = "",
    tool_input: []const u8 = "",
    timestamp: i64 = 0,
    raw_json: []const u8 = "",
};

pub const Session = struct {
    id: u64,
    state: SessionState = .starting,
    terminal_buffer: RingBuffer,
    hook_events: std.ArrayList(HookEvent),
    allocator: std.mem.Allocator,
    created_at: i64,
    prompt_context: ?PromptContext = null,
    command: []const u8 = "",
    cwd: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, id: u64) !Session {
        return .{
            .id = id,
            .terminal_buffer = try RingBuffer.init(allocator, RingBuffer.default_capacity),
            .hook_events = .empty,
            .allocator = allocator,
            .created_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Session) void {
        self.terminal_buffer.deinit();
        self.hook_events.deinit(self.allocator);
    }

    pub fn appendTerminalOutput(self: *Session, data: []const u8) void {
        self.terminal_buffer.write(data);
    }

    pub fn addHookEvent(self: *Session, event: HookEvent) !void {
        try self.hook_events.append(self.allocator, event);
    }

    pub fn setWaitingInput(self: *Session, summary: []const u8, options: []const []const u8) void {
        self.state = .waiting_input;
        self.prompt_context = .{
            .summary = summary,
            .options = options,
        };
    }

    pub fn clearPromptContext(self: *Session) void {
        self.state = .running;
        self.prompt_context = null;
    }
};

test "session state transitions" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();

    try std.testing.expectEqual(SessionState.starting, s.state);

    s.state = .running;
    try std.testing.expectEqual(SessionState.running, s.state);

    s.setWaitingInput("What would you like to do?", &.{ "Continue", "Stop" });
    try std.testing.expectEqual(SessionState.waiting_input, s.state);
    try std.testing.expectEqualStrings("What would you like to do?", s.prompt_context.?.summary);
    try std.testing.expectEqual(@as(usize, 2), s.prompt_context.?.options.len);

    s.clearPromptContext();
    try std.testing.expectEqual(SessionState.running, s.state);
    try std.testing.expect(s.prompt_context == null);
}

test "ring buffer" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, 8);
    defer rb.deinit();

    rb.write("hello");
    var out: [16]u8 = undefined;
    const n = rb.getContents(&out);
    try std.testing.expectEqualStrings("hello", out[0..n]);

    // Overflow test
    rb.write("world!!!");
    const n2 = rb.getContents(&out);
    try std.testing.expectEqual(@as(usize, 8), n2);
}
