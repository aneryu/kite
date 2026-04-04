const std = @import("std");
const posix = std.posix;
const Pty = @import("pty.zig").Pty;
const Session = @import("session.zig").Session;
const WsBroadcaster = @import("ws.zig").WsBroadcaster;
const protocol = @import("protocol.zig");
const prompt_parser = @import("prompt_parser.zig");

pub const SessionManager = struct {
    sessions: std.AutoHashMap(u64, *ManagedSession),
    allocator: std.mem.Allocator,
    broadcaster: *WsBroadcaster,
    next_id: u64 = 1,
    mutex: std.Thread.Mutex = .{},

    pub const ManagedSession = struct {
        session: Session,
        pty: Pty,
        relay_thread: ?std.Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    };

    pub const CreateOptions = struct {
        command: []const u8 = "claude",
        cwd: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, broadcaster: *WsBroadcaster) SessionManager {
        return .{
            .sessions = std.AutoHashMap(u64, *ManagedSession).init(allocator),
            .allocator = allocator,
            .broadcaster = broadcaster,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |ms_ptr| {
            const ms = ms_ptr.*;
            ms.running.store(false, .release);
            ms.pty.close();
            ms.session.deinit();
            self.allocator.destroy(ms);
        }
        self.sessions.deinit();
    }

    pub fn createSession(self: *SessionManager, opts: CreateOptions) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var ms = try self.allocator.create(ManagedSession);
        errdefer self.allocator.destroy(ms);

        ms.* = .{
            .session = try Session.init(self.allocator, id),
            .pty = try Pty.open(),
        };
        ms.session.state = .starting;
        ms.session.command = opts.command;
        ms.session.cwd = opts.cwd;

        const cmd_z = try self.allocator.dupeZ(u8, opts.command);
        defer self.allocator.free(cmd_z);
        const argv = [_]?[*:0]const u8{ cmd_z.ptr, null };
        try ms.pty.spawn(&argv, null);
        ms.session.state = .running;

        try self.sessions.put(id, ms);

        ms.relay_thread = try std.Thread.spawn(.{}, ioRelay, .{ self, ms });

        return id;
    }

    pub fn destroySession(self: *SessionManager, id: u64) void {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return;
        };
        _ = self.sessions.remove(id);
        self.mutex.unlock();

        ms.running.store(false, .release);
        ms.pty.close();
        ms.session.deinit();
        self.allocator.destroy(ms);
    }

    pub fn getSession(self: *SessionManager, id: u64) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sessions.get(id)) |ms| {
            return &ms.session;
        }
        return null;
    }

    pub fn getManagedSession(self: *SessionManager, id: u64) ?*ManagedSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.get(id);
    }

    pub fn writeToSession(self: *SessionManager, id: u64, data: []const u8) !void {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();
        try ms.pty.writeMaster(data);
    }

    pub fn resizeSession(self: *SessionManager, id: u64, rows: u16, cols: u16) void {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();
        ms.pty.setWindowSize(rows, cols);
    }

    pub fn listSessions(self: *SessionManager, allocator: std.mem.Allocator) ![]SessionInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list: std.ArrayList(SessionInfo) = .empty;
        errdefer list.deinit(allocator);

        var it = self.sessions.valueIterator();
        while (it.next()) |ms_ptr| {
            const ms = ms_ptr.*;
            try list.append(allocator, .{
                .id = ms.session.id,
                .state = ms.session.state,
                .command = ms.session.command,
                .cwd = ms.session.cwd,
            });
        }

        return list.toOwnedSlice(allocator);
    }

    pub fn handleHookEvent(self: *SessionManager, session_id: u64, event_name: []const u8, raw_json: []const u8) void {
        const session = self.getSession(session_id) orelse return;

        if (std.mem.eql(u8, event_name, "Stop")) {
            const parsed = std.json.parseFromSlice(StopPayload, self.allocator, raw_json, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();

            if (prompt_parser.isWaitingForInput(parsed.value.stop_reason)) {
                const tail = getTerminalTail(session);
                const summary = prompt_parser.extractSummary(tail);
                const options = prompt_parser.extractOptions(self.allocator, tail) catch &.{};

                session.setWaitingInput(summary, options);

                const msg = protocol.encodePromptRequest(self.allocator, session.id, summary, options) catch return;
                defer self.allocator.free(msg);
                self.broadcaster.broadcast(msg);
            }
        } else if (std.mem.eql(u8, event_name, "SessionStart")) {
            session.state = .running;
            session.clearPromptContext();
        }

        const state_msg = protocol.encodeSessionStateChange(self.allocator, session.id, session.state) catch return;
        defer self.allocator.free(state_msg);
        self.broadcaster.broadcast(state_msg);
    }

    fn getTerminalTail(session: *Session) []const u8 {
        const sl = session.terminal_buffer.slice();
        if (sl.second.len > 0) return sl.second;
        return sl.first;
    }

    fn ioRelay(self: *SessionManager, ms: *ManagedSession) void {
        var buf: [4096]u8 = undefined;

        while (ms.running.load(.acquire) and ms.pty.isChildAlive()) {
            var fds = [1]posix.pollfd{
                .{ .fd = ms.pty.master, .events = posix.POLL.IN, .revents = 0 },
            };
            const ready = posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;

            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(ms.pty.master, &buf) catch break;
                if (n == 0) break;
                const data = buf[0..n];

                ms.session.appendTerminalOutput(data);

                const msg = protocol.encodeTerminalOutput(self.allocator, data) catch continue;
                defer self.allocator.free(msg);
                self.broadcaster.broadcast(msg);
            }
            if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;
        }

        ms.session.state = .stopped;
        const status_msg = protocol.encodeSessionStateChange(self.allocator, ms.session.id, .stopped) catch return;
        defer self.allocator.free(status_msg);
        self.broadcaster.broadcast(status_msg);
    }
};

pub const SessionInfo = struct {
    id: u64,
    state: @import("session.zig").SessionState,
    command: []const u8,
    cwd: []const u8,
};

const StopPayload = struct {
    stop_reason: []const u8 = "",
};

test "session manager init/deinit" {
    const allocator = std.testing.allocator;
    var broadcaster = WsBroadcaster.init(allocator);
    defer broadcaster.deinit();

    var mgr = SessionManager.init(allocator, &broadcaster);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.sessions.count());
}
