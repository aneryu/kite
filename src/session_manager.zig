const std = @import("std");
const posix = std.posix;
const Pty = @import("pty.zig").Pty;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const WsBroadcaster = @import("ws.zig").WsBroadcaster;
const protocol = @import("protocol.zig");
const prompt_parser = @import("prompt_parser.zig");

pub const SessionManager = struct {
    sessions: std.AutoHashMap(u64, *ManagedSession),
    allocator: std.mem.Allocator,
    broadcaster: *WsBroadcaster,
    next_id: u64 = 1,
    mutex: std.Thread.Mutex = .{},

    pub const max_sessions: usize = 8;

    pub const ManagedSession = struct {
        session: Session,
        pty: Pty,
        relay_thread: ?std.Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        /// File descriptor for locally attached terminal (-1 = none)
        local_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    };

    pub const CreateOptions = struct {
        command: []const u8 = "claude",
        cwd: []const u8 = "",
        rows: u16 = 24,
        cols: u16 = 80,
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
            if (ms.session.command.len > 0) self.allocator.free(ms.session.command);
            if (ms.session.cwd.len > 0) self.allocator.free(ms.session.cwd);
            ms.session.deinit();
            self.allocator.destroy(ms);
        }
        self.sessions.deinit();
    }

    pub fn createSession(self: *SessionManager, opts: CreateOptions) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.count() >= max_sessions) {
            return error.TooManySessions;
        }

        const id = self.next_id;
        self.next_id += 1;

        var ms = try self.allocator.create(ManagedSession);
        errdefer self.allocator.destroy(ms);

        ms.* = .{
            .session = try Session.init(self.allocator, id),
            .pty = try Pty.open(),
        };
        ms.session.state = .starting;
        ms.session.command = try self.allocator.dupe(u8, opts.command);
        ms.session.cwd = try self.allocator.dupe(u8, opts.cwd);

        // Set PTY window size BEFORE spawn so the child sees correct dimensions
        ms.pty.setWindowSize(opts.rows, opts.cols);

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
        if (ms.session.command.len > 0) self.allocator.free(ms.session.command);
        if (ms.session.cwd.len > 0) self.allocator.free(ms.session.cwd);
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

    /// Attach a local terminal fd to a session. PTY output will be written to this fd.
    pub fn attachLocal(self: *SessionManager, id: u64, fd: posix.fd_t) bool {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return false;
        };
        self.mutex.unlock();
        ms.local_fd.store(@intCast(fd), .release);
        return true;
    }

    /// Detach the local terminal from a session.
    pub fn detachLocal(self: *SessionManager, id: u64) void {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();
        ms.local_fd.store(-1, .release);
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
                .tasks = ms.session.tasks.items,
                .subagents = ms.session.subagents.items,
                .current_activity = ms.session.current_activity,
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

                const msg = protocol.encodePromptRequest(self.allocator, session.id, summary, options, session.state) catch return;
                defer self.allocator.free(msg);
                self.broadcaster.broadcast(msg);
            } else if (std.mem.eql(u8, parsed.value.stop_reason, "end_turn")) {
                session.state = .idle;
            }
        } else if (std.mem.eql(u8, event_name, "UserPromptSubmit")) {
            session.clearPromptContext();
        } else if (std.mem.eql(u8, event_name, "SessionStart")) {
            session.state = .running;
            session.clearPromptContext();
        } else if (std.mem.eql(u8, event_name, "PreToolUse")) {
            self.handlePreToolUse(session, raw_json);
        } else if (std.mem.eql(u8, event_name, "PostToolUse") or std.mem.eql(u8, event_name, "PostToolUseFailure")) {
            // Clear current activity on tool completion or failure
            if (session.current_activity) |act| {
                self.allocator.free(act.tool_name);
                if (act.summary.len > 0) self.allocator.free(act.summary);
            }
            session.current_activity = null;
            if (session.state == .asking) {
                session.state = .running;
            }
            const ws_msg = protocol.encodeActivityUpdate(self.allocator, session.id, null) catch return;
            defer self.allocator.free(ws_msg);
            self.broadcaster.broadcast(ws_msg);
        } else if (std.mem.eql(u8, event_name, "TaskCreated")) {
            self.handleTaskCreated(session, raw_json);
        } else if (std.mem.eql(u8, event_name, "TaskCompleted")) {
            self.handleTaskCompleted(session, raw_json);
        } else if (std.mem.eql(u8, event_name, "SubagentStart")) {
            self.handleSubagentStart(session, raw_json);
        } else if (std.mem.eql(u8, event_name, "SubagentStop")) {
            self.handleSubagentStop(session, raw_json);
        }

        const state_msg = protocol.encodeSessionStateChange(self.allocator, session.id, session.state) catch return;
        defer self.allocator.free(state_msg);
        self.broadcaster.broadcast(state_msg);
    }

    const AskOption = struct { label: []const u8 = "" };
    const AskQuestion = struct { question: []const u8 = "", options: []const AskOption = &.{} };
    const AskPayload = struct {
        tool_name: []const u8 = "",
        tool_input: ?struct {
            questions: []const AskQuestion = &.{},
        } = null,
    };

    fn handlePreToolUse(self: *SessionManager, session: *Session, raw_json: []const u8) void {
        const Payload = struct { tool_name: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.tool_name, "AskUserQuestion")) {
            session.state = .asking;

            // Try to parse question and options from tool_input
            var question_text: []const u8 = "";
            var option_labels: []const []const u8 = &.{};
            const ask_parsed = std.json.parseFromSlice(AskPayload, self.allocator, raw_json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch null;

            if (ask_parsed) |ap| {
                if (ap.value.tool_input) |ti| {
                    if (ti.questions.len > 0) {
                        const q = ti.questions[0];
                        question_text = self.allocator.dupe(u8, q.question) catch "";
                        if (q.options.len > 0) {
                            var labels: std.ArrayList([]const u8) = .empty;
                            for (q.options) |opt| {
                                labels.append(self.allocator, self.allocator.dupe(u8, opt.label) catch continue) catch continue;
                            }
                            option_labels = labels.toOwnedSlice(self.allocator) catch &.{};
                        }
                    }
                }
                ap.deinit();
            }

            session.setWaitingInput(question_text, option_labels);
            session.state = .asking;

            const msg = protocol.encodePromptRequest(self.allocator, session.id, question_text, option_labels, session.state) catch return;
            defer self.allocator.free(msg);
            self.broadcaster.broadcast(msg);
            return;
        }

        session.state = .running;

        if (session.current_activity) |act| {
            self.allocator.free(act.tool_name);
            if (act.summary.len > 0) self.allocator.free(act.summary);
        }
        session.current_activity = .{
            .tool_name = self.allocator.dupe(u8, parsed.value.tool_name) catch return,
        };
        const ws_msg = protocol.encodeActivityUpdate(self.allocator, session.id, parsed.value.tool_name) catch return;
        defer self.allocator.free(ws_msg);
        self.broadcaster.broadcast(ws_msg);
    }

    fn handleTaskCreated(self: *SessionManager, session: *Session, raw_json: []const u8) void {
        const Payload = struct { task_id: []const u8 = "", task_subject: []const u8 = "", task_description: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const task = session_mod.TaskInfo{
            .id = self.allocator.dupe(u8, parsed.value.task_id) catch return,
            .subject = self.allocator.dupe(u8, parsed.value.task_subject) catch return,
            .description = if (parsed.value.task_description.len > 0) self.allocator.dupe(u8, parsed.value.task_description) catch return else "",
        };
        session.tasks.append(self.allocator, task) catch return;
        const ws_msg = protocol.encodeTaskUpdate(self.allocator, session.id, task.id, task.subject, false) catch return;
        defer self.allocator.free(ws_msg);
        self.broadcaster.broadcast(ws_msg);
    }

    fn handleTaskCompleted(self: *SessionManager, session: *Session, raw_json: []const u8) void {
        const Payload = struct { task_id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        for (session.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, parsed.value.task_id)) {
                task.completed = true;
                const ws_msg = protocol.encodeTaskUpdate(self.allocator, session.id, task.id, task.subject, true) catch return;
                defer self.allocator.free(ws_msg);
                self.broadcaster.broadcast(ws_msg);
                break;
            }
        }
    }

    fn handleSubagentStart(self: *SessionManager, session: *Session, raw_json: []const u8) void {
        const Payload = struct { agent_id: []const u8 = "", agent_type: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const sa = session_mod.SubagentInfo{
            .id = self.allocator.dupe(u8, parsed.value.agent_id) catch return,
            .agent_type = self.allocator.dupe(u8, parsed.value.agent_type) catch return,
            .started_at = std.time.timestamp(),
        };
        session.subagents.append(self.allocator, sa) catch return;
        const ws_msg = protocol.encodeSubagentUpdate(self.allocator, session.id, sa.id, sa.agent_type, false, 0) catch return;
        defer self.allocator.free(ws_msg);
        self.broadcaster.broadcast(ws_msg);
    }

    fn handleSubagentStop(self: *SessionManager, session: *Session, raw_json: []const u8) void {
        const Payload = struct { agent_id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        for (session.subagents.items) |*sa| {
            if (std.mem.eql(u8, sa.id, parsed.value.agent_id)) {
                sa.completed = true;
                sa.elapsed_ms = (std.time.timestamp() - sa.started_at) * 1000;
                const ws_msg = protocol.encodeSubagentUpdate(self.allocator, session.id, sa.id, sa.agent_type, true, sa.elapsed_ms) catch return;
                defer self.allocator.free(ws_msg);
                self.broadcaster.broadcast(ws_msg);
                break;
            }
        }
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

                // Write to locally attached terminal
                const lfd = ms.local_fd.load(.acquire);
                if (lfd >= 0) {
                    _ = posix.write(@intCast(lfd), data) catch {};
                }

                // Broadcast to WebSocket clients
                const msg = protocol.encodeTerminalOutput(self.allocator, data, ms.session.id) catch continue;
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
    tasks: []const @import("session.zig").TaskInfo,
    subagents: []const @import("session.zig").SubagentInfo,
    current_activity: ?@import("session.zig").ActivityInfo = null,
};

const StopPayload = struct {
    stop_reason: []const u8 = "",
};

test "session limit" {
    const allocator = std.testing.allocator;
    var broadcaster = WsBroadcaster.init(allocator);
    defer broadcaster.deinit();

    var mgr = SessionManager.init(allocator, &broadcaster);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 8), SessionManager.max_sessions);
}

test "session manager init/deinit" {
    const allocator = std.testing.allocator;
    var broadcaster = WsBroadcaster.init(allocator);
    defer broadcaster.deinit();

    var mgr = SessionManager.init(allocator, &broadcaster);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.sessions.count());
}
