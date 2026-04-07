const std = @import("std");
const posix = std.posix;
const Pty = @import("pty.zig").Pty;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const protocol = @import("protocol.zig");

const log = @import("log.zig");
fn logStderr(comptime fmt: []const u8, args: anytype) void {
    log.debug(fmt, args);
}

pub const PendingAsk = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    response: ?[]const u8 = null,
    tool_input_json: []const u8 = "",
};

pub const SessionInfo = struct {
    id: u64,
    state: session_mod.SessionState,
    command: []const u8,
    cwd: []const u8,
    tasks: []const session_mod.TaskInfo,
    subagents: []const session_mod.SubagentInfo,
    current_activity: ?session_mod.ActivityInfo = null,
    prompt_summary: []const u8 = "",
    prompt_options: []const []const u8 = &.{},
    prompt_questions: []const session_mod.PromptQuestion = &.{},
    last_message: []const u8 = "",
};

pub const PendingAskResult = struct {
    response: []const u8,
    tool_input_json: []const u8,
};

pub const SessionManager = struct {
    sessions: std.AutoHashMap(u64, *ManagedSession),
    allocator: std.mem.Allocator,
    broadcast_fn: *const fn ([]const u8) void,
    next_id: u64 = 1,
    mutex: std.Thread.Mutex = .{},
    pending_asks: std.AutoHashMap(u64, *PendingAsk),

    pub const max_sessions: usize = 8;

    pub const ManagedSession = struct {
        session: Session,
        pty: Pty,
        relay_thread: ?std.Thread = null,
        running: bool = true,
        destroying: bool = false,
        local_fd: posix.fd_t = -1,
    };

    pub const CreateOptions = struct {
        command: []const u8 = "claude",
        cwd: []const u8 = "",
        rows: u16 = 24,
        cols: u16 = 80,
    };

    pub fn init(allocator: std.mem.Allocator, broadcast_fn: *const fn ([]const u8) void) SessionManager {
        return .{
            .sessions = std.AutoHashMap(u64, *ManagedSession).init(allocator),
            .allocator = allocator,
            .broadcast_fn = broadcast_fn,
            .pending_asks = std.AutoHashMap(u64, *PendingAsk).init(allocator),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);

        self.mutex.lock();
        var it = self.sessions.keyIterator();
        while (it.next()) |id_ptr| {
            ids.append(self.allocator, id_ptr.*) catch break;
        }
        self.mutex.unlock();

        for (ids.items) |id| {
            self.destroySession(id);
        }

        self.sessions.deinit();

        self.mutex.lock();
        var pa_it = self.pending_asks.valueIterator();
        while (pa_it.next()) |pa_ptr| {
            pa_ptr.*.mutex.lock();
            if (pa_ptr.*.response == null) {
                pa_ptr.*.response = self.allocator.dupe(u8, "{}") catch "";
            }
            pa_ptr.*.cond.signal();
            pa_ptr.*.mutex.unlock();
        }
        self.pending_asks.deinit();
        self.mutex.unlock();
    }

    pub fn createPendingAsk(self: *SessionManager, session_id: u64) !*PendingAsk {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_asks.get(session_id)) |existing| {
            return existing;
        }

        const pa = try self.allocator.create(PendingAsk);
        pa.* = .{};
        try self.pending_asks.put(session_id, pa);
        return pa;
    }

    pub fn waitPendingAsk(self: *SessionManager, session_id: u64) ?PendingAskResult {
        self.mutex.lock();
        const pa = self.pending_asks.get(session_id) orelse {
            self.mutex.unlock();
            return null;
        };
        self.mutex.unlock();

        pa.mutex.lock();
        while (pa.response == null) {
            pa.cond.wait(&pa.mutex);
        }
        const result = PendingAskResult{
            .response = pa.response.?,
            .tool_input_json = pa.tool_input_json,
        };
        pa.mutex.unlock();

        self.mutex.lock();
        _ = self.pending_asks.remove(session_id);
        self.mutex.unlock();
        self.allocator.destroy(pa);

        return result;
    }

    fn resolvePendingAsk(self: *SessionManager, session_id: u64, response: []const u8) bool {
        self.mutex.lock();
        const pa = self.pending_asks.get(session_id) orelse {
            self.mutex.unlock();
            return false;
        };
        self.mutex.unlock();

        pa.mutex.lock();
        if (pa.response != null) {
            pa.mutex.unlock();
            return true;
        }
        pa.response = self.allocator.dupe(u8, response) catch null;
        pa.cond.signal();
        pa.mutex.unlock();
        return true;
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
        errdefer ms.session.deinit();
        errdefer ms.pty.close();

        ms.session.command = try self.allocator.dupe(u8, opts.command);

        if (opts.cwd.len > 0) {
            ms.session.cwd = try self.allocator.dupe(u8, opts.cwd);
        } else {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch "";
            ms.session.cwd = try self.allocator.dupe(u8, cwd);
        }

        ms.pty.setWindowSize(opts.rows, opts.cols);

        // Split command string into argv parts (space-separated)
        var argv_list: std.ArrayList(?[*:0]const u8) = .empty;
        defer {
            for (argv_list.items) |item| {
                if (item) |ptr| {
                    // Recover the sentinel-terminated slice to free it
                    const slice = std.mem.span(ptr);
                    self.allocator.free(slice[0 .. slice.len + 1]);
                }
            }
            argv_list.deinit(self.allocator);
        }

        var cmd_iter = std.mem.splitScalar(u8, opts.command, ' ');
        while (cmd_iter.next()) |part| {
            if (part.len == 0) continue;
            const part_z = try self.allocator.dupeZ(u8, part);
            try argv_list.append(self.allocator, part_z.ptr);
        }
        try argv_list.append(self.allocator, null); // null terminator

        const cwd_z: ?[*:0]const u8 = if (ms.session.cwd.len > 0)
            (self.allocator.dupeZ(u8, ms.session.cwd) catch null)
        else
            null;
        defer if (cwd_z) |z| self.allocator.free(z[0 .. ms.session.cwd.len + 1]);

        try ms.pty.spawnCwd(argv_list.items, null, cwd_z);

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
        ms.destroying = true;
        ms.running = false;
        ms.local_fd = -1;
        self.mutex.unlock();

        ms.pty.close();
        if (ms.relay_thread) |thread| {
            thread.join();
        }

        if (ms.session.command.len > 0) self.allocator.free(ms.session.command);
        if (ms.session.cwd.len > 0) self.allocator.free(ms.session.cwd);
        ms.session.deinit();
        self.allocator.destroy(ms);
    }

    pub fn sessionExists(self: *SessionManager, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.contains(id);
    }

    pub fn getSessionState(self: *SessionManager, id: u64) ?session_mod.SessionState {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ms = self.sessions.get(id) orelse return null;
        return ms.session.state;
    }

    pub fn getSessionSnapshot(self: *SessionManager, allocator: std.mem.Allocator, id: u64) ?SessionInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ms = self.sessions.get(id) orelse return null;
        return dupSessionInfo(allocator, ms.session) catch null;
    }

    pub fn listSessions(self: *SessionManager, allocator: std.mem.Allocator) ![]SessionInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list: std.ArrayList(SessionInfo) = .empty;
        errdefer {
            for (list.items) |info| freeSessionInfo(allocator, info);
            list.deinit(allocator);
        }

        var it = self.sessions.valueIterator();
        while (it.next()) |ms_ptr| {
            try list.append(allocator, try dupSessionInfo(allocator, ms_ptr.*.session));
        }

        return list.toOwnedSlice(allocator);
    }

    pub fn freeSessionList(allocator: std.mem.Allocator, sessions: []SessionInfo) void {
        for (sessions) |info| freeSessionInfo(allocator, info);
        allocator.free(sessions);
    }

    pub fn freeSessionSnapshot(allocator: std.mem.Allocator, info: SessionInfo) void {
        freeSessionInfo(allocator, info);
    }

    pub fn getTerminalSnapshot(self: *SessionManager, allocator: std.mem.Allocator, id: u64) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ms = self.sessions.get(id) orelse return null;
        const slice = ms.session.terminal_buffer.slice();
        const total_len = slice.first.len + slice.second.len;
        const out = allocator.alloc(u8, total_len) catch return null;
        @memcpy(out[0..slice.first.len], slice.first);
        @memcpy(out[slice.first.len..], slice.second);
        return out;
    }

    pub fn writeToSession(self: *SessionManager, id: u64, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ms = self.sessions.get(id) orelse return error.SessionNotFound;
        if (ms.destroying) return error.SessionNotFound;
        try ms.pty.writeMaster(data);
    }

    pub fn resizeSession(self: *SessionManager, id: u64, rows: u16, cols: u16) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ms = self.sessions.get(id) orelse return false;
        if (ms.destroying) return false;
        ms.pty.setWindowSize(rows, cols);
        return true;
    }

    pub fn attachLocal(self: *SessionManager, id: u64, fd: posix.fd_t) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ms = self.sessions.get(id) orelse return false;
        if (ms.destroying) return false;
        ms.local_fd = fd;
        return true;
    }

    pub fn detachLocal(self: *SessionManager, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ms = self.sessions.get(id) orelse return;
        ms.local_fd = -1;
    }

    pub fn handleHookEvent(self: *SessionManager, session_id: u64, event_name: []const u8, raw_json: []const u8) void {
        const hooks_mod = @import("hooks.zig");
        const event_type = hooks_mod.HookEventType.fromString(event_name) orelse return;

        var msgs: [6]?[]const u8 = .{null} ** 6;
        defer for (&msgs) |*m| if (m.*) |msg| self.allocator.free(msg);

        self.mutex.lock();
        const ms = self.sessions.get(session_id) orelse {
            self.mutex.unlock();
            return;
        };
        const session = &ms.session;

        const changes = session.applyEvent(event_type, raw_json);

        if (changes.state)
            msgs[0] = protocol.encodeSessionStateChange(self.allocator, session.id, session.state) catch null;
        if (changes.prompt) {
            if (session.state == .asking) {
                if (session.prompt_context) |pc| {
                    msgs[1] = protocol.encodeAskPromptRequest(self.allocator, session.id, pc.questions, session.state) catch null;
                }
            } else if (session.prompt_context) |pc| {
                msgs[1] = protocol.encodePromptRequest(self.allocator, session.id, pc.summary, pc.options, session.state) catch null;
            }
        }
        if (changes.activity)
            msgs[2] = protocol.encodeActivityUpdate(self.allocator, session.id, if (session.current_activity) |act| act.tool_name else null) catch null;
        if (changes.last_message)
            msgs[3] = protocol.encodeLastMessageUpdate(self.allocator, session.id, session.last_message) catch null;
        if (changes.task) {
            if (changes.task_idx) |idx| {
                const task = session.tasks.items[idx];
                msgs[4] = protocol.encodeTaskUpdate(self.allocator, session.id, task.id, task.subject, task.completed) catch null;
            }
        }
        if (changes.subagent) {
            if (changes.subagent_idx) |idx| {
                const sa = session.subagents.items[idx];
                msgs[5] = protocol.encodeSubagentUpdate(self.allocator, session.id, sa.id, sa.agent_type, sa.description, sa.completed, sa.elapsed_ms) catch null;
            }
        }
        self.mutex.unlock();

        for (msgs) |msg| if (msg) |m| self.broadcast_fn(m);
    }

    pub fn resolvePromptResponse(self: *SessionManager, session_id: u64, text: []const u8) void {
        logStderr("[kite] resolvePromptResponse: session_id={d} text={s}", .{ session_id, text });

        var should_write_to_pty = false;
        var should_resolve_pending = false;
        var next_state: ?session_mod.SessionState = null;

        self.mutex.lock();
        const ms = self.sessions.get(session_id) orelse {
            self.mutex.unlock();
            return;
        };

        if (ms.session.state == .asking) {
            should_resolve_pending = true;
            next_state = .running;
        } else if (ms.session.state == .waiting) {
            should_write_to_pty = true;
            next_state = .running;
        } else {
            should_write_to_pty = true;
            next_state = ms.session.state;
        }

        ms.session.clearPrompt();
        if (next_state) |state| ms.session.state = state;
        self.mutex.unlock();

        if (should_resolve_pending and !self.resolvePendingAsk(session_id, text)) {
            should_write_to_pty = true;
        }

        if (should_write_to_pty) {
            self.writeResponseToPty(session_id, text);
        }

        if (next_state) |state| {
            const state_msg = protocol.encodeSessionStateChange(self.allocator, session_id, state) catch return;
            defer self.allocator.free(state_msg);
            self.broadcast_fn(state_msg);
        }
    }

    fn writeResponseToPty(self: *SessionManager, session_id: u64, text: []const u8) void {
        var input_buf: [4097]u8 = undefined;
        if (text.len < input_buf.len - 1) {
            @memcpy(input_buf[0..text.len], text);
            input_buf[text.len] = '\r';
            self.writeToSession(session_id, input_buf[0 .. text.len + 1]) catch {};
            logStderr("[kite] writeResponseToPty: wrote {d} bytes", .{text.len + 1});
        }
    }

    fn dupSessionInfo(allocator: std.mem.Allocator, session: Session) !SessionInfo {
        var info = SessionInfo{
            .id = session.id,
            .state = session.state,
            .command = try allocator.dupe(u8, session.command),
            .cwd = try allocator.dupe(u8, session.cwd),
            .tasks = try dupTasks(allocator, session.tasks.items),
            .subagents = try dupSubagents(allocator, session.subagents.items),
            .last_message = try allocator.dupe(u8, session.last_message),
        };
        errdefer freeSessionInfo(allocator, info);

        if (session.current_activity) |act| {
            info.current_activity = .{
                .tool_name = try allocator.dupe(u8, act.tool_name),
                .summary = try allocator.dupe(u8, act.summary),
            };
        }

        if (session.prompt_context) |pc| {
            info.prompt_summary = try allocator.dupe(u8, pc.summary);
            info.prompt_options = try dupStringSlice(allocator, pc.options);
            info.prompt_questions = try dupQuestions(allocator, pc.questions);
        }

        return info;
    }

    fn ioRelay(self: *SessionManager, ms: *ManagedSession) void {
        var buf: [4096]u8 = undefined;

        while (true) {
            self.mutex.lock();
            const keep_running = ms.running and !ms.destroying;
            self.mutex.unlock();
            if (!keep_running or !ms.pty.isChildAlive()) break;

            var fds = [1]posix.pollfd{
                .{ .fd = ms.pty.master, .events = posix.POLL.IN, .revents = 0 },
            };
            const ready = posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;

            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(ms.pty.master, &buf) catch break;
                if (n == 0) break;
                const data = buf[0..n];

                var local_fd: posix.fd_t = -1;
                self.mutex.lock();
                ms.session.appendTerminalOutput(data);
                local_fd = ms.local_fd;
                self.mutex.unlock();

                if (local_fd >= 0) {
                    _ = posix.write(local_fd, data) catch {};
                }

                const msg = protocol.encodeTerminalOutput(self.allocator, data, ms.session.id) catch continue;
                defer self.allocator.free(msg);
                self.broadcast_fn(msg);
            }

            if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;
        }

        self.mutex.lock();
        const should_emit = !ms.destroying;
        ms.running = false;
        ms.session.state = .stopped;
        self.mutex.unlock();

        if (should_emit) {
            const status_msg = protocol.encodeSessionStateChange(self.allocator, ms.session.id, .stopped) catch return;
            defer self.allocator.free(status_msg);
            self.broadcast_fn(status_msg);
        }
    }
};

pub fn freeSessionInfo(allocator: std.mem.Allocator, info: SessionInfo) void {
    allocator.free(info.command);
    allocator.free(info.cwd);
    for (info.tasks) |task| {
        allocator.free(task.id);
        allocator.free(task.subject);
        if (task.description.len > 0) allocator.free(task.description);
    }
    if (info.tasks.len > 0) allocator.free(info.tasks);
    for (info.subagents) |sa| {
        allocator.free(sa.id);
        allocator.free(sa.agent_type);
        if (sa.description.len > 0) allocator.free(sa.description);
    }
    if (info.subagents.len > 0) allocator.free(info.subagents);
    if (info.current_activity) |act| {
        allocator.free(act.tool_name);
        if (act.summary.len > 0) allocator.free(act.summary);
    }
    if (info.prompt_summary.len > 0) allocator.free(info.prompt_summary);
    for (info.prompt_options) |opt| if (opt.len > 0) allocator.free(opt);
    if (info.prompt_options.len > 0) allocator.free(info.prompt_options);
    for (info.prompt_questions) |q| {
        if (q.question.len > 0) allocator.free(q.question);
        for (q.options) |opt| if (opt.len > 0) allocator.free(opt);
        if (q.options.len > 0) allocator.free(q.options);
    }
    if (info.prompt_questions.len > 0) allocator.free(info.prompt_questions);
    if (info.last_message.len > 0) allocator.free(info.last_message);
}

fn dupStringSlice(allocator: std.mem.Allocator, input: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    for (input) |item| {
        try out.append(allocator, try allocator.dupe(u8, item));
    }
    return out.toOwnedSlice(allocator);
}

fn dupQuestions(allocator: std.mem.Allocator, input: []const session_mod.PromptQuestion) ![]const session_mod.PromptQuestion {
    var out: std.ArrayList(session_mod.PromptQuestion) = .empty;
    errdefer {
        for (out.items) |q| {
            allocator.free(q.question);
            for (q.options) |opt| allocator.free(opt);
            if (q.options.len > 0) allocator.free(q.options);
        }
        out.deinit(allocator);
    }
    for (input) |q| {
        try out.append(allocator, .{
            .question = try allocator.dupe(u8, q.question),
            .options = try dupStringSlice(allocator, q.options),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn dupTasks(allocator: std.mem.Allocator, input: []const session_mod.TaskInfo) ![]const session_mod.TaskInfo {
    var out: std.ArrayList(session_mod.TaskInfo) = .empty;
    errdefer {
        for (out.items) |task| {
            allocator.free(task.id);
            allocator.free(task.subject);
            if (task.description.len > 0) allocator.free(task.description);
        }
        out.deinit(allocator);
    }
    for (input) |task| {
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, task.id),
            .subject = try allocator.dupe(u8, task.subject),
            .description = if (task.description.len > 0) try allocator.dupe(u8, task.description) else "",
            .completed = task.completed,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn dupSubagents(allocator: std.mem.Allocator, input: []const session_mod.SubagentInfo) ![]const session_mod.SubagentInfo {
    var out: std.ArrayList(session_mod.SubagentInfo) = .empty;
    errdefer {
        for (out.items) |sa| {
            allocator.free(sa.id);
            allocator.free(sa.agent_type);
            if (sa.description.len > 0) allocator.free(sa.description);
        }
        out.deinit(allocator);
    }
    for (input) |sa| {
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, sa.id),
            .agent_type = try allocator.dupe(u8, sa.agent_type),
            .description = if (sa.description.len > 0) try allocator.dupe(u8, sa.description) else "",
            .completed = sa.completed,
            .started_at = sa.started_at,
            .elapsed_ms = sa.elapsed_ms,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn noopBroadcast(_: []const u8) void {}

test "session limit" {
    const allocator = std.testing.allocator;

    var mgr = SessionManager.init(allocator, &noopBroadcast);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 8), SessionManager.max_sessions);
}

test "session manager init/deinit" {
    const allocator = std.testing.allocator;

    var mgr = SessionManager.init(allocator, &noopBroadcast);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.sessions.count());
}
