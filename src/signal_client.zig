const std = @import("std");
const MessageQueue = @import("message_queue.zig").MessageQueue;

fn logStderr(comptime fmt: []const u8, args: anytype) void {
    const stderr_file = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    var writer = stderr_file.writer(&buf);
    const w = &writer.interface;
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

/// Minimal WebSocket client for connecting to the signaling server.
/// Performs HTTP upgrade handshake, sends masked frames (RFC 6455),
/// and runs a read loop that pushes incoming messages to a MessageQueue.
pub const SignalClient = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    queue: *MessageQueue,
    connected: bool = false,
    pairing_code: []const u8, // owned, freed in deinit

    // Connection params stored for reconnect
    host: []const u8, // owned
    port: u16,
    path: []const u8, // owned
    role: []const u8 = "daemon",

    // Member ID assigned by the signal server on join
    member_id: ?[]const u8 = null, // owned

    // Reconnect backoff
    reconnect_delay_ms: u64 = 2000,
    max_reconnect_delay_ms: u64 = 30000,

    /// Connect to the signaling server and perform the WebSocket upgrade handshake.
    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
        queue: *MessageQueue,
        pairing_code: []const u8,
    ) !SignalClient {
        const stream = try wsHandshake(allocator, host, port, path);

        return .{
            .stream = stream,
            .allocator = allocator,
            .queue = queue,
            .connected = true,
            .pairing_code = try allocator.dupe(u8, pairing_code),
            .host = try allocator.dupe(u8, host),
            .port = port,
            .path = try allocator.dupe(u8, path),
        };
    }

    pub fn deinit(self: *SignalClient) void {
        self.connected = false;
        self.stream.close();
        self.allocator.free(self.pairing_code);
        self.allocator.free(self.host);
        self.allocator.free(self.path);
        if (self.member_id) |mid| self.allocator.free(mid);
    }

    /// Send a masked text WebSocket frame (RFC 6455).
    pub fn sendText(self: *SignalClient, payload: []const u8) !void {
        // Build frame header
        var header_buf: [14]u8 = undefined; // max header: 2 + 8 + 4 (we only use up to 2+2+4=8)
        var header_len: usize = 0;

        // Byte 0: FIN + opcode text
        header_buf[0] = 0x81;
        header_len += 1;

        // Byte 1: MASK bit + payload length
        if (payload.len < 126) {
            header_buf[1] = @as(u8, @intCast(payload.len)) | 0x80;
            header_len += 1;
        } else if (payload.len <= 65535) {
            header_buf[1] = 126 | 0x80;
            header_buf[2] = @intCast(payload.len >> 8);
            header_buf[3] = @intCast(payload.len & 0xFF);
            header_len += 3;
        } else {
            return error.PayloadTooLarge;
        }

        // 4-byte mask key
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(header_buf[header_len..][0..4], &mask);
        header_len += 4;

        // Send header
        _ = try self.stream.write(header_buf[0..header_len]);

        // Send masked payload in chunks
        var masked_buf: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < payload.len) {
            const chunk_len = @min(masked_buf.len, payload.len - offset);
            for (0..chunk_len) |i| {
                masked_buf[i] = payload[offset + i] ^ mask[(offset + i) % 4];
            }
            _ = try self.stream.write(masked_buf[0..chunk_len]);
            offset += chunk_len;
        }
    }

    /// Convenience: send a JSON string as a text frame.
    pub fn sendJson(self: *SignalClient, json: []const u8) !void {
        return self.sendText(json);
    }

    /// Join the signal topic as a daemon (new topic-based protocol).
    pub fn joinTopic(self: *SignalClient) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"join\",\"pairing_code\":\"{s}\",\"role\":\"{s}\"}}",
            .{ self.pairing_code, self.role },
        );
        defer self.allocator.free(msg);
        try self.sendText(msg);
    }

    /// Reconnect to the signal server by creating a new TCP connection
    /// and performing the WebSocket upgrade handshake.
    fn reconnect(self: *SignalClient) !void {
        self.stream = try wsHandshake(self.allocator, self.host, self.port, self.path);
        self.connected = true;
    }

    /// Read loop with auto-reconnect — runs in its own thread.
    /// On disconnect, retries with exponential backoff.
    pub fn readLoop(self: *SignalClient) void {
        while (true) {
            self.readLoopInner() catch {};
            self.connected = false;

            // Free stale member_id on disconnect
            if (self.member_id) |mid| {
                self.allocator.free(mid);
                self.member_id = null;
            }

            logStderr("[signal] Disconnected, reconnecting in {d}ms...", .{self.reconnect_delay_ms});
            std.Thread.sleep(self.reconnect_delay_ms * std.time.ns_per_ms);

            // Try to reconnect
            self.reconnect() catch {
                self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, self.max_reconnect_delay_ms);
                continue;
            };

            // Re-join the topic
            self.joinTopic() catch {
                self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, self.max_reconnect_delay_ms);
                continue;
            };

            // Reset backoff on successful reconnect
            self.reconnect_delay_ms = 2000;
            logStderr("[signal] Reconnected successfully", .{});
        }
    }

    fn readLoopInner(self: *SignalClient) !void {
        while (self.connected) {
            // Read 2-byte frame header
            var hdr: [2]u8 = undefined;
            try readExact(&self.stream, &hdr);

            const opcode = hdr[0] & 0x0F;
            const is_masked = (hdr[1] & 0x80) != 0;
            var payload_len: u64 = hdr[1] & 0x7F;

            if (payload_len == 126) {
                var ext: [2]u8 = undefined;
                try readExact(&self.stream, &ext);
                payload_len = @as(u64, ext[0]) << 8 | @as(u64, ext[1]);
            } else if (payload_len == 127) {
                var ext: [8]u8 = undefined;
                try readExact(&self.stream, &ext);
                payload_len = 0;
                inline for (0..8) |i| {
                    payload_len = (payload_len << 8) | @as(u64, ext[i]);
                }
            }

            // Read mask key if present
            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (is_masked) {
                try readExact(&self.stream, &mask);
            }

            // Limit payload size to prevent OOM
            if (payload_len > 1_048_576) return error.PayloadTooLarge;

            // Read payload
            const payload = try self.allocator.alloc(u8, @intCast(payload_len));
            defer self.allocator.free(payload);
            if (payload.len > 0) {
                try readExact(&self.stream, payload);
            }

            // Unmask if needed
            if (is_masked) {
                for (payload, 0..) |*b, i| {
                    b.* ^= mask[i % 4];
                }
            }

            switch (opcode) {
                0x1 => {
                    // Text frame — parse member_id from joined response, then push to queue
                    self.parseMemberId(payload);
                    self.queue.push(payload) catch {};
                },
                0x9 => {
                    // Ping — send pong (masked, empty payload)
                    self.sendPong() catch {};
                },
                0x8 => {
                    // Close
                    return;
                },
                else => {
                    // Ignore unknown opcodes
                },
            }
        }
    }

    fn sendPong(self: *SignalClient) !void {
        // Pong frame: FIN + opcode 0xA, masked, zero-length payload
        var frame: [6]u8 = undefined;
        frame[0] = 0x8A; // FIN + pong
        frame[1] = 0x80; // MASK bit, length 0
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(frame[2..6], &mask);
        _ = try self.stream.write(&frame);
    }

    /// Parse member_id from a "joined" response and store it.
    fn parseMemberId(self: *SignalClient, payload: []const u8) void {
        // Look for "type":"joined" and extract "member_id":"..."
        if (std.mem.indexOf(u8, payload, "\"joined\"") == null) return;

        const key = "\"member_id\":\"";
        const start_idx = std.mem.indexOf(u8, payload, key) orelse return;
        const value_start = start_idx + key.len;
        if (value_start >= payload.len) return;
        const rest = payload[value_start..];
        const end_idx = std.mem.indexOf(u8, rest, "\"") orelse return;
        const member_id_str = rest[0..end_idx];

        // Free old member_id if any
        if (self.member_id) |mid| self.allocator.free(mid);
        self.member_id = self.allocator.dupe(u8, member_id_str) catch null;

        if (self.member_id) |mid| {
            logStderr("[signal] Joined topic, member_id={s}", .{mid});
        }
    }
};

/// Perform TCP connection + WebSocket upgrade handshake.
fn wsHandshake(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) !std.net.Stream {
    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    errdefer stream.close();

    // Send WebSocket upgrade request
    const request = try std.fmt.allocPrint(allocator,
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}:{d}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n", .{ path, host, port });
    defer allocator.free(request);

    _ = try stream.write(request);

    // Read response and check for 101
    var resp_buf: [1024]u8 = undefined;
    const n = try stream.read(&resp_buf);
    if (n == 0) return error.ConnectionClosed;

    const response = resp_buf[0..n];
    if (std.mem.indexOf(u8, response, "101") == null) {
        return error.UpgradeFailed;
    }

    return stream;
}

/// Read exactly `buf.len` bytes from the stream.
fn readExact(stream: *std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}
