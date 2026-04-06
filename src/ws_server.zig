const std = @import("std");
const MessageQueue = @import("message_queue.zig").MessageQueue;
const log = @import("log.zig");

const max_clients = 8;
const max_payload_size = 1_048_576; // 1MB
const ws_magic_guid = "258EAFA5-E914-47DA-95CA-5AB5DC7085B6";

pub const WsClient = struct {
    stream: std.net.Stream,
    authenticated: bool,
    alive: bool,
};

pub const WsServer = struct {
    server: std.net.Server,
    clients: [max_clients]?WsClient,
    mutex: std.Thread.Mutex,
    queue: *MessageQueue,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, port: u16, queue: *MessageQueue) !WsServer {
        const address = try std.net.Address.parseIp4("0.0.0.0", port);
        const server = try address.listen(.{ .reuse_address = true });

        return .{
            .server = server,
            .clients = .{null} ** max_clients,
            .mutex = .{},
            .queue = queue,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.clients) |*slot| {
            if (slot.*) |*client| {
                client.stream.close();
                slot.* = null;
            }
        }
        self.server.deinit();
    }

    /// Public entry point — run from a dedicated thread.
    pub fn run(self: *WsServer) void {
        self.acceptLoop();
    }

    fn acceptLoop(self: *WsServer) void {
        log.debug("[ws] WebSocket server listening", .{});

        while (true) {
            const conn = self.server.accept() catch |err| {
                log.debug("[ws] Accept error: {}", .{err});
                continue;
            };

            // Find a free slot
            const slot_idx = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();

                for (self.clients[0..], 0..) |_, i| {
                    if (self.clients[i] == null) {
                        self.clients[i] = WsClient{
                            .stream = conn.stream,
                            .authenticated = false,
                            .alive = true,
                        };
                        break :blk i;
                    }
                }
                // No free slots — close immediately
                log.debug("[ws] Max clients reached, rejecting connection", .{});
                conn.stream.close();
                break :blk null;
            };

            if (slot_idx) |idx| {
                const thread = std.Thread.spawn(.{}, clientThread, .{ self, idx }) catch |err| {
                    log.debug("[ws] Failed to spawn client thread: {}", .{err});
                    self.removeClient(idx);
                    continue;
                };
                thread.detach();
            }
        }
    }

    fn clientThread(self: *WsServer, slot: usize) void {
        defer self.removeClient(slot);

        // Get stream from slot
        const stream = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.clients[slot]) |client| {
                break :blk client.stream;
            }
            return;
        };

        log.debug("[ws] Client connected (slot {})", .{slot});

        // Perform WebSocket handshake
        var stream_mut = stream;
        doHandshake(self.allocator, &stream_mut) catch |err| {
            log.debug("[ws] Handshake failed (slot {}): {}", .{ slot, err });
            return;
        };

        log.debug("[ws] Handshake complete (slot {})", .{slot});

        // Read loop
        self.readLoop(slot, &stream_mut);
    }

    fn readLoop(self: *WsServer, slot: usize, stream: *std.net.Stream) void {
        while (true) {
            // Check if still alive
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.clients[slot] == null) return;
                if (!self.clients[slot].?.alive) return;
            }

            // Read 2-byte frame header
            var hdr: [2]u8 = undefined;
            readExact(stream, &hdr) catch return;

            const opcode = hdr[0] & 0x0F;
            const is_masked = (hdr[1] & 0x80) != 0;
            var payload_len: u64 = hdr[1] & 0x7F;

            if (payload_len == 126) {
                var ext: [2]u8 = undefined;
                readExact(stream, &ext) catch return;
                payload_len = @as(u64, ext[0]) << 8 | @as(u64, ext[1]);
            } else if (payload_len == 127) {
                var ext: [8]u8 = undefined;
                readExact(stream, &ext) catch return;
                payload_len = 0;
                inline for (0..8) |i| {
                    payload_len = (payload_len << 8) | @as(u64, ext[i]);
                }
            }

            // Read mask key if present (clients MUST mask per RFC 6455)
            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (is_masked) {
                readExact(stream, &mask) catch return;
            }

            // Limit payload size
            if (payload_len > max_payload_size) {
                log.debug("[ws] Payload too large from slot {}: {}", .{ slot, payload_len });
                return;
            }

            // Read payload
            const payload = self.allocator.alloc(u8, @intCast(payload_len)) catch return;
            defer self.allocator.free(payload);
            if (payload.len > 0) {
                readExact(stream, payload) catch return;
            }

            // Unmask
            if (is_masked) {
                for (payload, 0..) |*b, i| {
                    b.* ^= mask[i % 4];
                }
            }

            switch (opcode) {
                0x1 => {
                    // Text frame — push to message queue
                    self.queue.push(payload) catch |err| {
                        log.debug("[ws] Failed to push message: {}", .{err});
                    };
                },
                0x8 => {
                    // Close frame
                    log.debug("[ws] Client close (slot {})", .{slot});
                    return;
                },
                0x9 => {
                    // Ping — respond with pong
                    sendPong(stream, payload) catch return;
                },
                else => {
                    // Ignore unknown opcodes
                },
            }
        }
    }

    fn removeClient(self: *WsServer, slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.clients[slot]) |*client| {
            client.stream.close();
            self.clients[slot] = null;
            log.debug("[ws] Client removed (slot {})", .{slot});
        }
    }

    /// Send unmasked text frame to a single stream.
    fn sendFrame(stream: *std.net.Stream, payload: []const u8) !void {
        var header_buf: [10]u8 = undefined;
        var header_len: usize = 0;

        // FIN + text opcode
        header_buf[0] = 0x81;
        header_len = 1;

        if (payload.len < 126) {
            header_buf[1] = @intCast(payload.len);
            header_len = 2;
        } else if (payload.len <= 65535) {
            header_buf[1] = 126;
            header_buf[2] = @intCast(payload.len >> 8);
            header_buf[3] = @intCast(payload.len & 0xFF);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            const len64: u64 = @intCast(payload.len);
            inline for (0..8) |i| {
                header_buf[2 + i] = @intCast((len64 >> @intCast(56 - i * 8)) & 0xFF);
            }
            header_len = 10;
        }

        _ = try stream.write(header_buf[0..header_len]);
        if (payload.len > 0) {
            _ = try stream.write(payload);
        }
    }

    /// Send unmasked pong frame (server to client does not mask).
    fn sendPong(stream: *std.net.Stream, payload: []const u8) !void {
        var header_buf: [10]u8 = undefined;
        var header_len: usize = 0;

        // FIN + pong opcode
        header_buf[0] = 0x8A;
        header_len = 1;

        if (payload.len < 126) {
            header_buf[1] = @intCast(payload.len);
            header_len = 2;
        } else if (payload.len <= 65535) {
            header_buf[1] = 126;
            header_buf[2] = @intCast(payload.len >> 8);
            header_buf[3] = @intCast(payload.len & 0xFF);
            header_len = 4;
        } else {
            // Pong payload shouldn't be this large, but handle it
            header_buf[1] = 127;
            const len64: u64 = @intCast(payload.len);
            inline for (0..8) |i| {
                header_buf[2 + i] = @intCast((len64 >> @intCast(56 - i * 8)) & 0xFF);
            }
            header_len = 10;
        }

        _ = try stream.write(header_buf[0..header_len]);
        if (payload.len > 0) {
            _ = try stream.write(payload);
        }
    }

    /// Broadcast a text message to all connected clients.
    pub fn broadcast(self: *WsServer, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.clients) |*slot| {
            if (slot.*) |*client| {
                if (client.alive) {
                    var stream = client.stream;
                    sendFrame(&stream, message) catch {
                        client.alive = false;
                    };
                }
            }
        }
    }

    /// Mark all connected clients as authenticated.
    pub fn markAllAuthenticated(self: *WsServer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.clients) |*slot| {
            if (slot.*) |*client| {
                client.authenticated = true;
            }
        }
    }

    /// Mark a specific client slot as authenticated.
    pub fn setAuthenticated(self: *WsServer, slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (slot < max_clients) {
            if (self.clients[slot]) |*client| {
                client.authenticated = true;
            }
        }
    }
};

/// Perform WebSocket handshake: read HTTP upgrade request, send 101 response.
fn doHandshake(allocator: std.mem.Allocator, stream: *std.net.Stream) !void {
    var buf: [4096]u8 = undefined;
    var total: usize = 0;

    // Read the HTTP request until we see \r\n\r\n
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;

        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }

    const request = buf[0..total];

    // Extract Sec-WebSocket-Key
    const key = extractHeader(request, "Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;

    // Compute Sec-WebSocket-Accept
    const accept_value = computeAccept(allocator, key) catch return error.HandshakeFailed;
    defer allocator.free(accept_value);

    // Send 101 response
    const response = std.fmt.allocPrint(allocator,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n" ++
        "\r\n", .{accept_value}) catch return error.HandshakeFailed;
    defer allocator.free(response);

    _ = try stream.write(response);
}

/// Extract a header value from an HTTP request.
fn extractHeader(request: []const u8, name: []const u8) ?[]const u8 {
    // Search for "Name: value\r\n" (case-insensitive for the name)
    var i: usize = 0;
    while (i < request.len) {
        // Find start of line
        const line_start = i;

        // Find end of line
        const line_end = std.mem.indexOf(u8, request[i..], "\r\n") orelse request.len - i;
        const line = request[line_start .. line_start + line_end];

        // Check if line starts with the header name (case-insensitive)
        if (line.len > name.len + 2) {
            const header_part = line[0..name.len];
            if (std.ascii.eqlIgnoreCase(header_part, name)) {
                if (line[name.len] == ':') {
                    // Skip ": " and trim
                    var val_start = name.len + 1;
                    while (val_start < line.len and line[val_start] == ' ') {
                        val_start += 1;
                    }
                    return line[val_start..];
                }
            }
        }

        i = line_start + line_end + 2; // skip past \r\n
        if (i <= line_start) break; // prevent infinite loop
    }
    return null;
}

/// Compute the Sec-WebSocket-Accept value per RFC 6455.
fn computeAccept(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    // Concatenate key + magic GUID
    const concat = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, ws_magic_guid });
    defer allocator.free(concat);

    // SHA-1 hash
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &hash, .{});

    // Base64 encode
    const encoded_len = std.base64.standard.Encoder.calcSize(hash.len);
    const result = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(result, &hash);

    return result;
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

test "compute websocket accept" {
    const allocator = std.testing.allocator;
    // RFC 6455 Section 4.2.2 example
    const result = try computeAccept(allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("nbjRpG3gptX6DDitfAQfnUM2EYI=", result);
}

test "extract header" {
    const request = "GET / HTTP/1.1\r\nHost: localhost\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nUpgrade: websocket\r\n\r\n";
    const key = extractHeader(request, "Sec-WebSocket-Key");
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", key.?);

    const host = extractHeader(request, "Host");
    try std.testing.expect(host != null);
    try std.testing.expectEqualStrings("localhost", host.?);

    const missing = extractHeader(request, "X-Missing");
    try std.testing.expect(missing == null);
}
