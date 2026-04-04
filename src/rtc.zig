const std = @import("std");
const MessageQueue = @import("message_queue.zig").MessageQueue;

const c = @cImport({
    @cInclude("rtc/rtc.h");
});

pub const RtcError = error{
    InvalidArgument,
    RuntimeFailure,
    NotAvailable,
    BufferTooSmall,
};

fn checkResult(result: c_int) RtcError!void {
    if (result >= 0) return;
    return switch (result) {
        c.RTC_ERR_INVALID => RtcError.InvalidArgument,
        c.RTC_ERR_FAILURE => RtcError.RuntimeFailure,
        c.RTC_ERR_NOT_AVAIL => RtcError.NotAvailable,
        c.RTC_ERR_TOO_SMALL => RtcError.BufferTooSmall,
        else => RtcError.RuntimeFailure,
    };
}

pub const RtcConfig = struct {
    stun_server: []const u8 = "stun:stun.l.google.com:19302",
    turn_server: ?[]const u8 = null,
};

pub const RtcPeer = struct {
    pc: c_int = -1,
    dc: c_int = -1,
    queue: *MessageQueue,
    state_queue: *MessageQueue,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        config: RtcConfig,
        queue: *MessageQueue,
        state_queue: *MessageQueue,
    ) !RtcPeer {
        var self = RtcPeer{
            .queue = queue,
            .state_queue = state_queue,
            .allocator = allocator,
        };

        // Build ICE server list
        var servers: [2][*c]const u8 = undefined;
        var server_count: c_int = 0;

        const stun_z = try allocator.dupeZ(u8, config.stun_server);
        defer allocator.free(stun_z);
        servers[@intCast(server_count)] = stun_z.ptr;
        server_count += 1;

        var turn_z: ?[:0]u8 = null;
        defer if (turn_z) |t| allocator.free(t);
        if (config.turn_server) |turn| {
            turn_z = try allocator.dupeZ(u8, turn);
            servers[@intCast(server_count)] = turn_z.?.ptr;
            server_count += 1;
        }

        var rtc_config: c.rtcConfiguration = std.mem.zeroes(c.rtcConfiguration);
        rtc_config.iceServers = &servers;
        rtc_config.iceServersCount = server_count;

        const pc = c.rtcCreatePeerConnection(&rtc_config);
        if (pc < 0) return RtcError.RuntimeFailure;
        self.pc = pc;

        // Store self pointer as user data for callbacks
        c.rtcSetUserPointer(pc, @ptrCast(&self));

        // Set callbacks
        try checkResult(c.rtcSetLocalDescriptionCallback(pc, onLocalDescription));
        try checkResult(c.rtcSetLocalCandidateCallback(pc, onLocalCandidate));
        try checkResult(c.rtcSetStateChangeCallback(pc, onStateChange));
        try checkResult(c.rtcSetDataChannelCallback(pc, onDataChannel));

        return self;
    }

    pub fn deinit(self: *RtcPeer) void {
        if (self.dc >= 0) {
            _ = c.rtcDeleteDataChannel(self.dc);
            self.dc = -1;
        }
        if (self.pc >= 0) {
            _ = c.rtcDeletePeerConnection(self.pc);
            self.pc = -1;
        }
    }

    pub fn setRemoteDescription(self: *RtcPeer, sdp: []const u8, sdp_type: []const u8) !void {
        const sdp_z = try self.allocator.dupeZ(u8, sdp);
        defer self.allocator.free(sdp_z);
        const type_z = try self.allocator.dupeZ(u8, sdp_type);
        defer self.allocator.free(type_z);
        try checkResult(c.rtcSetRemoteDescription(self.pc, sdp_z.ptr, type_z.ptr));
    }

    pub fn addRemoteCandidate(self: *RtcPeer, candidate: []const u8, mid: []const u8) !void {
        const cand_z = try self.allocator.dupeZ(u8, candidate);
        defer self.allocator.free(cand_z);
        const mid_z = try self.allocator.dupeZ(u8, mid);
        defer self.allocator.free(mid_z);
        try checkResult(c.rtcAddRemoteCandidate(self.pc, cand_z.ptr, mid_z.ptr));
    }

    pub fn send(self: *RtcPeer, data: []const u8) !void {
        if (self.dc < 0) return RtcError.NotAvailable;
        try checkResult(c.rtcSendMessage(self.dc, data.ptr, @intCast(data.len)));
    }

    // -- C callbacks (run on libdatachannel internal threads) --

    fn onLocalDescription(_: c_int, sdp_raw: [*c]const u8, type_raw: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = peerFromPtr(ptr) orelse return;
        const sdp_esc = jsonEscapeAlloc(self.allocator, std.mem.span(sdp_raw)) catch return;
        defer self.allocator.free(sdp_esc);
        const type_esc = jsonEscapeAlloc(self.allocator, std.mem.span(type_raw)) catch return;
        defer self.allocator.free(type_esc);
        const msg = std.fmt.allocPrint(self.allocator, "{{\"type\":\"local_description\",\"sdp\":\"{s}\",\"sdp_type\":\"{s}\"}}", .{
            sdp_esc,
            type_esc,
        }) catch return;
        defer self.allocator.free(msg);
        self.state_queue.push(msg) catch return;
    }

    fn onLocalCandidate(_: c_int, cand_raw: [*c]const u8, mid_raw: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = peerFromPtr(ptr) orelse return;
        const cand_esc = jsonEscapeAlloc(self.allocator, std.mem.span(cand_raw)) catch return;
        defer self.allocator.free(cand_esc);
        const mid_esc = jsonEscapeAlloc(self.allocator, std.mem.span(mid_raw)) catch return;
        defer self.allocator.free(mid_esc);
        const msg = std.fmt.allocPrint(self.allocator, "{{\"type\":\"local_candidate\",\"candidate\":\"{s}\",\"mid\":\"{s}\"}}", .{
            cand_esc,
            mid_esc,
        }) catch return;
        defer self.allocator.free(msg);
        self.state_queue.push(msg) catch return;
    }

    fn onStateChange(_: c_int, state: c.rtcState, ptr: ?*anyopaque) callconv(.c) void {
        const self = peerFromPtr(ptr) orelse return;
        const state_str = switch (state) {
            c.RTC_NEW => "new",
            c.RTC_CONNECTING => "connecting",
            c.RTC_CONNECTED => "connected",
            c.RTC_DISCONNECTED => "disconnected",
            c.RTC_FAILED => "failed",
            c.RTC_CLOSED => "closed",
            else => "unknown",
        };
        const msg = std.fmt.allocPrint(self.allocator, "{{\"type\":\"state_change\",\"state\":\"{s}\"}}", .{state_str}) catch return;
        defer self.allocator.free(msg);
        self.state_queue.push(msg) catch return;
    }

    fn onDataChannel(_: c_int, dc: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = peerFromPtr(ptr) orelse return;
        self.dc = dc;
        c.rtcSetUserPointer(dc, @ptrCast(self));
        _ = c.rtcSetOpenCallback(dc, onOpen);
        _ = c.rtcSetMessageCallback(dc, onMessage);
    }

    fn onOpen(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = peerFromPtr(ptr) orelse return;
        self.state_queue.push("{\"type\":\"dc_open\"}") catch return;
    }

    fn onMessage(_: c_int, msg_raw: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = peerFromPtr(ptr) orelse return;
        if (size < 0) {
            // Negative size means text message (null-terminated string)
            const text = std.mem.span(msg_raw);
            self.queue.push(text) catch return;
        } else {
            // Positive size means binary message
            const data: [*]const u8 = @ptrCast(msg_raw);
            self.queue.push(data[0..@intCast(size)]) catch return;
        }
    }

    fn peerFromPtr(ptr: ?*anyopaque) ?*RtcPeer {
        return @alignCast(@ptrCast(ptr orelse return null));
    }

    fn jsonEscapeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        for (input) |byte| {
            switch (byte) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => {
                    if (byte < 0x20) {
                        const hex = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{byte});
                        defer allocator.free(hex);
                        try out.appendSlice(allocator, hex);
                    } else {
                        try out.append(allocator, byte);
                    }
                },
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn initLogger(level: c.rtcLogLevel) void {
    c.rtcInitLogger(level, null);
}

pub fn cleanup() void {
    c.rtcCleanup();
}

test "RtcPeer json escape" {
    const allocator = std.testing.allocator;
    const result = try RtcPeer.jsonEscapeAlloc(allocator, "hello\"world\\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\\\"world\\\\n", result);
}
