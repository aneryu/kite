const std = @import("std");

/// Thread-safe FIFO queue for passing messages between threads.
/// Bridges callback threads (e.g. libdatachannel) to the main event loop.
/// Producers call `push()` from any thread, the main loop calls `drain()`
/// to retrieve all pending messages at once.
pub const MessageQueue = struct {
    items: std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MessageQueue {
        return .{
            .items = .empty,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit(self.allocator);
    }

    /// Dupes the data and appends it to the queue. Safe to call from any thread.
    pub fn push(self: *MessageQueue, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const duped = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(duped);
        try self.items.append(self.allocator, duped);
    }

    /// Returns all pending messages as an owned slice and clears the queue.
    /// Caller must free the batch with `freeBatch()`.
    /// Returns `&.{}` if nothing is pending.
    pub fn drain(self: *MessageQueue) ![][]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) {
            return &.{};
        }

        const batch = try self.allocator.dupe([]u8, self.items.items);
        self.items.clearRetainingCapacity();
        return batch;
    }

    /// Frees a batch returned by `drain()`.
    pub fn freeBatch(self: *MessageQueue, batch: [][]u8) void {
        if (batch.len == 0) return;
        for (batch) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(batch);
    }
};

test "message queue push and drain" {
    const allocator = std.testing.allocator;
    var q = MessageQueue.init(allocator);
    defer q.deinit();

    try q.push("hello");
    try q.push("world");

    const batch = try q.drain();
    defer q.freeBatch(batch);

    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectEqualStrings("hello", batch[0]);
    try std.testing.expectEqualStrings("world", batch[1]);

    // Second drain should be empty
    const batch2 = try q.drain();
    defer q.freeBatch(batch2);
    try std.testing.expectEqual(@as(usize, 0), batch2.len);
}

test "message queue concurrent push" {
    const allocator = std.testing.allocator;
    var q = MessageQueue.init(allocator);
    defer q.deinit();

    const Thread = std.Thread;
    const thread_count = 4;

    const S = struct {
        fn worker(queue: *MessageQueue, id: u8) void {
            const msg = &[_]u8{ 'T', id };
            queue.push(msg) catch @panic("push failed");
        }
    };

    var threads: [thread_count]Thread = undefined;
    for (0..thread_count) |i| {
        threads[i] = try Thread.spawn(.{}, S.worker, .{ &q, @as(u8, @intCast(i)) });
    }
    for (&threads) |*t| {
        t.join();
    }

    const batch = try q.drain();
    defer q.freeBatch(batch);

    try std.testing.expectEqual(@as(usize, thread_count), batch.len);
}
