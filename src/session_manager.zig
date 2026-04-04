const std = @import("std");
const posix = std.posix;
const Pty = @import("pty.zig").Pty;
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const WsBroadcaster = @import("ws.zig").WsBroadcaster;
const protocol = @import("protocol.zig");
const prompt_parser = @import("prompt_parser.zig");

fn logStderr(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.fs.File.stderr();
    const out = std.fmt.allocPrint(std.heap.page_allocator, fmt ++ "\n", args) catch return;
    defer std.heap.page_allocator.free(out);
    _ = stderr.write(out) catch {};
}

pub const PendingAsk = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    response: ?[]const u8 = null,
    /// Original tool_input JSON for building PermissionRequest hook output
    tool_input_json: []const u8 = "",
};

pub const SessionManager = struct {
    sessions: std.AutoHashMap(u64, *ManagedSession),
    allocator: std.mem.Allocator,
    broadcaster: *WsBroadcaster,
    next_id: u64 = 1,
    mutex: std.Thread.Mutex = .{},
    pending_asks: std.AutoHashMap(u64, *PendingAsk) = std.AutoHashMap(u64, *PendingAsk).init(std.heap.page_allocator),

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
            .pending_asks = std.AutoHashMap(u64, *PendingAsk).init(allocator),
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
        // Clean up any remaining pending asks
        var pa_it = self.pending_asks.valueIterator();
        while (pa_it.next()) |pa_ptr| {
            self.allocator.destroy(pa_ptr.*);
        }
        self.pending_asks.deinit();
    }

    /// Create a pending ask slot for a session. Called before broadcasting the question.
    pub fn createPendingAsk(self: *SessionManager, session_id: u64) !*PendingAsk {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pa = try self.allocator.create(PendingAsk);
        pa.* = .{};
        try self.pending_asks.put(session_id, pa);
        return pa;
    }

    pub const PendingAskResult = struct {
        /// User's answer (JSON-encoded answers map). Caller owns.
        response: []const u8,
        /// Original tool_input JSON for building updatedInput. Caller owns.
        tool_input_json: []const u8,
    };

    /// Block until the user responds to a pending ask. Returns response + tool_input (caller owns both).
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

        // Clean up — must unlock pa.mutex BEFORE destroy to avoid use-after-free
        self.mutex.lock();
        _ = self.pending_asks.remove(session_id);
        self.mutex.unlock();
        self.allocator.destroy(pa);

        return result;
    }

    /// Signal a pending ask with the user's response.
    fn resolvePendingAsk(self: *SessionManager, session_id: u64, response: []const u8) bool {
        self.mutex.lock();
        const pa = self.pending_asks.get(session_id) orelse {
            self.mutex.unlock();
            return false;
        };
        self.mutex.unlock();

        pa.mutex.lock();
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
        ms.session.state = .starting;
        ms.session.command = try self.allocator.dupe(u8, opts.command);

        // Resolve cwd: use specified directory, or fall back to current working directory
        if (opts.cwd.len > 0) {
            ms.session.cwd = try self.allocator.dupe(u8, opts.cwd);
        } else {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch "";
            ms.session.cwd = try self.allocator.dupe(u8, cwd);
        }

        // Set PTY window size BEFORE spawn so the child sees correct dimensions
        ms.pty.setWindowSize(opts.rows, opts.cols);

        const cmd_z = try self.allocator.dupeZ(u8, opts.command);
        defer self.allocator.free(cmd_z);
        const argv = [_]?[*:0]const u8{ cmd_z.ptr, null };

        // Spawn child in the specified working directory
        const cwd_z: ?[*:0]const u8 = if (ms.session.cwd.len > 0)
            (self.allocator.dupeZ(u8, ms.session.cwd) catch null)
        else
            null;
        defer if (cwd_z) |z| self.allocator.free(z[0 .. ms.session.cwd.len + 1]);
        try ms.pty.spawnCwd(&argv, null, cwd_z);
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
                .prompt_summary = if (ms.session.prompt_context) |pc| pc.summary else "",
                .prompt_options = if (ms.session.prompt_context) |pc| pc.options else &.{},
                .prompt_questions = if (ms.session.prompt_context) |pc| pc.questions else &.{},
                .last_message = ms.session.last_message,
            });
        }

        return list.toOwnedSlice(allocator);
    }

    fn setLastMessage(self: *SessionManager, session: *Session, msg: []const u8) void {
        if (session.last_message.len > 0) self.allocator.free(session.last_message);
        session.last_message = self.allocator.dupe(u8, msg) catch "";
    }

    pub fn handleHookEvent(self: *SessionManager, session_id: u64, event_name: []const u8, raw_json: []const u8) void {
        const session = self.getSession(session_id) orelse return;

        if (std.mem.eql(u8, event_name, "Notification")) {
            const NPayload = struct { notification_message: []const u8 = "" };
            const np = std.json.parseFromSlice(NPayload, self.allocator, raw_json, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer np.deinit();
            if (np.value.notification_message.len > 0) {
                self.setLastMessage(session, np.value.notification_message);
                const lm_msg = protocol.encodeLastMessageUpdate(self.allocator, session.id, np.value.notification_message) catch return;
                defer self.allocator.free(lm_msg);
                self.broadcaster.broadcast(lm_msg);
            }
            return;
        }

        if (std.mem.eql(u8, event_name, "Stop")) {
            const parsed = std.json.parseFromSlice(StopPayload, self.allocator, raw_json, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();

            if (prompt_parser.isWaitingForInput(parsed.value.stop_reason)) {
                // Free previous prompt_context if any
                self.freePromptContext(session);

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
            self.freePromptContext(session);
            session.clearPromptContext();
        } else if (std.mem.eql(u8, event_name, "SessionStart")) {
            session.state = .running;
            self.freePromptContext(session);
            session.clearPromptContext();
            self.setLastMessage(session, "Session started");
        } else if (std.mem.eql(u8, event_name, "PreToolUse")) {
            self.handlePreToolUse(session, raw_json);
        } else if (std.mem.eql(u8, event_name, "PermissionRequest")) {
            self.handlePermissionRequest(session, raw_json);
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

        // All PreToolUse events (including AskUserQuestion) just update activity.
        // AskUserQuestion prompt is handled via the PermissionRequest hook instead.
        session.state = .running;

        if (session.current_activity) |act| {
            self.allocator.free(act.tool_name);
            if (act.summary.len > 0) self.allocator.free(act.summary);
        }
        session.current_activity = .{
            .tool_name = self.allocator.dupe(u8, parsed.value.tool_name) catch return,
        };
        self.setLastMessage(session, parsed.value.tool_name);
        const ws_msg = protocol.encodeActivityUpdate(self.allocator, session.id, parsed.value.tool_name) catch return;
        defer self.allocator.free(ws_msg);
        self.broadcaster.broadcast(ws_msg);
    }

    /// Handle PermissionRequest hook. For AskUserQuestion, parses questions and broadcasts prompt.
    /// The actual blocking + response happens in handleHttpHook.
    fn handlePermissionRequest(self: *SessionManager, session: *Session, raw_json: []const u8) void {
        const Payload = struct { tool_name: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        if (!std.mem.eql(u8, parsed.value.tool_name, "AskUserQuestion")) return;

        session.state = .asking;
        self.freePromptContext(session);

        // Parse all questions with per-question options
        var questions: std.ArrayList(protocol.QuestionInfo) = .empty;
        var all_option_storage: std.ArrayList([]const u8) = .empty;
        var first_question: []const u8 = "";

        const ask_parsed = std.json.parseFromSlice(AskPayload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch null;

        if (ask_parsed) |ap| {
            if (ap.value.tool_input) |ti| {
                for (ti.questions, 0..) |q, qi| {
                    if (qi == 0) {
                        first_question = self.allocator.dupe(u8, q.question) catch "";
                    }
                    var q_opts: std.ArrayList([]const u8) = .empty;
                    for (q.options) |opt| {
                        const label = self.allocator.dupe(u8, opt.label) catch continue;
                        q_opts.append(self.allocator, label) catch continue;
                        all_option_storage.append(self.allocator, self.allocator.dupe(u8, opt.label) catch continue) catch continue;
                    }
                    questions.append(self.allocator, .{
                        .question = self.allocator.dupe(u8, q.question) catch "",
                        .options = q_opts.toOwnedSlice(self.allocator) catch &.{},
                    }) catch continue;
                }
            }
            ap.deinit();
        }

        const question_list = questions.toOwnedSlice(self.allocator) catch &.{};
        const flat_options = all_option_storage.toOwnedSlice(self.allocator) catch &.{};

        logStderr("[kite] PermissionRequest/AskUserQuestion: questions={d} total_options={d}", .{ question_list.len, flat_options.len });

        // Store full questions in prompt_context (owned by session)
        session.prompt_context = .{
            .summary = first_question,
            .options = flat_options,
            .questions = question_list,
        };
        session.state = .asking;

        // Broadcast with full questions structure
        const msg = protocol.encodeAskPromptRequest(self.allocator, session.id, question_list, session.state) catch return;
        defer self.allocator.free(msg);

        logStderr("[kite] Broadcasting prompt_request: {s}", .{msg});
        self.broadcaster.broadcast(msg);
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

    /// Free allocated strings in prompt_context before overwriting or clearing.
    fn freePromptContext(self: *SessionManager, session: *Session) void {
        if (session.prompt_context) |pc| {
            if (pc.summary.len > 0) self.allocator.free(pc.summary);
            for (pc.options) |opt| {
                if (opt.len > 0) self.allocator.free(opt);
            }
            if (pc.options.len > 0) self.allocator.free(pc.options);
            for (pc.questions) |q| {
                if (q.question.len > 0) self.allocator.free(q.question);
                for (q.options) |opt| {
                    if (opt.len > 0) self.allocator.free(opt);
                }
                if (q.options.len > 0) self.allocator.free(q.options);
            }
            if (pc.questions.len > 0) self.allocator.free(pc.questions);
            session.prompt_context = null;
        }
    }

    /// Called when user responds via web UI. For AskUserQuestion (.asking), signals the
    /// pending HTTP hook callback. For Stop-based prompts (.waiting_input), writes to PTY.
    pub fn resolvePromptResponse(self: *SessionManager, session_id: u64, text: []const u8) void {
        logStderr("[kite] resolvePromptResponse: session_id={d} text={s}", .{ session_id, text });

        if (self.getSession(session_id)) |session| {
            if (session.state == .asking) {
                // AskUserQuestion: return answer via pending HTTP hook callback
                if (self.resolvePendingAsk(session_id, text)) {
                    logStderr("[kite] resolvePromptResponse: signaled pending ask", .{});
                } else {
                    logStderr("[kite] resolvePromptResponse: no pending ask found, falling back to PTY", .{});
                    self.writeResponseToPty(session_id, text);
                }
            } else {
                // Stop/waiting_input: write to PTY
                self.writeResponseToPty(session_id, text);
            }

            self.freePromptContext(session);
            session.clearPromptContext();
            const state_msg = protocol.encodeSessionStateChange(self.allocator, session_id, session.state) catch return;
            defer self.allocator.free(state_msg);
            self.broadcaster.broadcast(state_msg);
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
    prompt_summary: []const u8 = "",
    prompt_options: []const []const u8 = &.{},
    prompt_questions: []const @import("session.zig").PromptQuestion = &.{},
    last_message: []const u8 = "",
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

test "parse AskUserQuestion payload" {
    const allocator = std.testing.allocator;
    const raw_json =
        \\{"session_id":"48b96eef","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which lesson?","header":"Lesson","options":[{"label":"Slash Commands (01)","description":"desc1"},{"label":"Memory (02)","description":"desc2"}],"multiSelect":false}]}}
    ;

    const AskOption = struct { label: []const u8 = "" };
    const AskQuestion = struct { question: []const u8 = "", options: []const AskOption = &.{} };
    const AskPayload = struct {
        tool_name: []const u8 = "",
        tool_input: ?struct {
            questions: []const AskQuestion = &.{},
        } = null,
    };

    const ask_parsed = try std.json.parseFromSlice(AskPayload, allocator, raw_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer ask_parsed.deinit();

    try std.testing.expectEqualStrings("AskUserQuestion", ask_parsed.value.tool_name);
    try std.testing.expect(ask_parsed.value.tool_input != null);
    const ti = ask_parsed.value.tool_input.?;
    try std.testing.expectEqual(@as(usize, 1), ti.questions.len);
    try std.testing.expectEqualStrings("Which lesson?", ti.questions[0].question);
    try std.testing.expectEqual(@as(usize, 2), ti.questions[0].options.len);
    try std.testing.expectEqualStrings("Slash Commands (01)", ti.questions[0].options[0].label);
    try std.testing.expectEqualStrings("Memory (02)", ti.questions[0].options[1].label);
}
