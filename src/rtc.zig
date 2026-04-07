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

pub const default_ice_servers = [_][]const u8{
    "stun:relay.fun.dev:3478",
    "stun:stun.qq.com:3478",
};

pub const RtcConfig = struct {
    ice_servers: []const []const u8 = &default_ice_servers,
};

const PendingCandidate = struct {
    candidate: []u8,
    mid: []u8,
};

pub const RtcPeer = struct {
    pc: c_int = -1,
    dc: c_int = -1,
    queue: *MessageQueue,
    state_queue: *MessageQueue,
    allocator: std.mem.Allocator,
    member_id: []const u8 = "",
    authenticated: bool = false,
    remote_description_set: bool = false,
    pending_candidates: std.ArrayList(PendingCandidate) = std.ArrayList(PendingCandidate).empty,

    /// Initialize RtcPeer fields (pc, dc remain -1).
    /// Call `setupPeerConnection` after the RtcPeer is at its final memory location.
    pub fn init(
        allocator: std.mem.Allocator,
        queue: *MessageQueue,
        state_queue: *MessageQueue,
        member_id: []const u8,
    ) RtcPeer {
        return .{
            .queue = queue,
            .state_queue = state_queue,
            .allocator = allocator,
            .member_id = member_id,
        };
    }

    /// Create the libdatachannel peer connection and set callbacks.
    /// Must be called after the RtcPeer is at its final heap location
    /// (so that the `self` pointer passed to C callbacks remains valid).
    pub fn setupPeerConnection(self: *RtcPeer, config: RtcConfig) !void {
        const max_servers = 16;
        var servers: [max_servers][*c]const u8 = undefined;
        var server_count: c_int = 0;

        var bufs: [max_servers][:0]u8 = undefined;
        for (config.ice_servers) |srv| {
            if (server_count >= max_servers) break;
            const idx: usize = @intCast(server_count);
            bufs[idx] = try self.allocator.dupeZ(u8, srv);
            servers[idx] = bufs[idx].ptr;
            server_count += 1;
        }
        defer {
            for (0..@intCast(server_count)) |i| {
                self.allocator.free(bufs[i]);
            }
        }

        var rtc_config: c.rtcConfiguration = std.mem.zeroes(c.rtcConfiguration);
        rtc_config.iceServers = &servers;
        rtc_config.iceServersCount = server_count;

        const pc = c.rtcCreatePeerConnection(&rtc_config);
        if (pc < 0) return RtcError.RuntimeFailure;
        self.pc = pc;

        // Store self pointer — safe because self is heap-allocated at final location
        c.rtcSetUserPointer(pc, @ptrCast(self));

        // Set callbacks
        try checkResult(c.rtcSetLocalDescriptionCallback(pc, onLocalDescription));
        try checkResult(c.rtcSetLocalCandidateCallback(pc, onLocalCandidate));
        try checkResult(c.rtcSetStateChangeCallback(pc, onStateChange));
        try checkResult(c.rtcSetDataChannelCallback(pc, onDataChannel));
    }

    pub fn deinit(self: *RtcPeer) void {
        if (self.dc >= 0) {
            _ = c.rtcClose(self.dc);
            self.dc = -1;
        }
        if (self.pc >= 0) {
            _ = c.rtcClosePeerConnection(self.pc);
            // Give libdatachannel time to clean up callbacks before deleting
            std.Thread.sleep(100 * std.time.ns_per_ms);
            _ = c.rtcDeletePeerConnection(self.pc);
            self.pc = -1;
        }
        for (self.pending_candidates.items) |pc| {
            self.allocator.free(pc.candidate);
            self.allocator.free(pc.mid);
        }
        self.pending_candidates.deinit(self.allocator);
    }

    pub fn setRemoteDescription(self: *RtcPeer, sdp: []const u8, sdp_type: []const u8) !void {
        const sdp_z = try self.allocator.dupeZ(u8, sdp);
        defer self.allocator.free(sdp_z);
        const type_z = try self.allocator.dupeZ(u8, sdp_type);
        defer self.allocator.free(type_z);
        try checkResult(c.rtcSetRemoteDescription(self.pc, sdp_z.ptr, type_z.ptr));
        self.remote_description_set = true;

        // Flush pending candidates that arrived before remote description
        for (self.pending_candidates.items) |pc| {
            const cand_z = self.allocator.dupeZ(u8, pc.candidate) catch continue;
            defer self.allocator.free(cand_z);
            const mid_z = self.allocator.dupeZ(u8, pc.mid) catch continue;
            defer self.allocator.free(mid_z);
            checkResult(c.rtcAddRemoteCandidate(self.pc, cand_z.ptr, mid_z.ptr)) catch {};
            self.allocator.free(pc.candidate);
            self.allocator.free(pc.mid);
        }
        self.pending_candidates.clearRetainingCapacity();
    }

    pub fn addRemoteCandidate(self: *RtcPeer, candidate: []const u8, mid: []const u8) !void {
        if (!self.remote_description_set) {
            // Buffer candidates until remote description is set
            const cand_copy = try self.allocator.dupe(u8, candidate);
            errdefer self.allocator.free(cand_copy);
            const mid_copy = try self.allocator.dupe(u8, mid);
            errdefer self.allocator.free(mid_copy);
            try self.pending_candidates.append(self.allocator, .{ .candidate = cand_copy, .mid = mid_copy });
            return;
        }
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
        const mid_esc = jsonEscapeAlloc(self.allocator, self.member_id) catch return;
        defer self.allocator.free(mid_esc);
        const msg = std.fmt.allocPrint(self.allocator, "{{\"type\":\"local_description\",\"member_id\":\"{s}\",\"sdp\":\"{s}\",\"sdp_type\":\"{s}\"}}", .{
            mid_esc,
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
        const member_id_esc = jsonEscapeAlloc(self.allocator, self.member_id) catch return;
        defer self.allocator.free(member_id_esc);
        const msg = std.fmt.allocPrint(self.allocator, "{{\"type\":\"local_candidate\",\"member_id\":\"{s}\",\"candidate\":\"{s}\",\"mid\":\"{s}\"}}", .{
            member_id_esc,
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
        const member_id_esc = jsonEscapeAlloc(self.allocator, self.member_id) catch return;
        defer self.allocator.free(member_id_esc);
        const msg = std.fmt.allocPrint(self.allocator, "{{\"type\":\"state_change\",\"member_id\":\"{s}\",\"state\":\"{s}\"}}", .{ member_id_esc, state_str }) catch return;
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
        const member_id_esc = jsonEscapeAlloc(self.allocator, self.member_id) catch return;
        defer self.allocator.free(member_id_esc);
        const msg = std.fmt.allocPrint(self.allocator, "{{\"type\":\"dc_open\",\"member_id\":\"{s}\"}}", .{member_id_esc}) catch return;
        defer self.allocator.free(msg);
        self.state_queue.push(msg) catch return;
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
