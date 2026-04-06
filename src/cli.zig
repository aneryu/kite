/// cli.zig — CLI presentation module for kite
/// Color utilities, Levenshtein fuzzy matching, help text, and error messages.
const std = @import("std");
const posix = std.posix;

// ---------------------------------------------------------------------------
// Part 1: Color utilities
// ---------------------------------------------------------------------------

pub const Color = enum {
    reset,
    bold,
    green,
    yellow,
    cyan,
};

var use_color: bool = false;

/// Call once at program start to detect whether stdout is a TTY.
pub fn init() void {
    use_color = posix.isatty(posix.STDOUT_FILENO);
}

/// Return the ANSI escape sequence for the given color, or "" if colors are disabled.
pub fn code(color: Color) []const u8 {
    if (!use_color) return "";
    return switch (color) {
        .reset => "\x1b[0m",
        .bold => "\x1b[1m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
    };
}

// ---------------------------------------------------------------------------
// Part 2: Levenshtein distance
// ---------------------------------------------------------------------------

/// Compute Optimal String Alignment (OSA) distance between slices a and b.
/// OSA extends standard Levenshtein by counting adjacent transpositions as a
/// single edit, which gives more intuitive results for real-world typos such
/// as "statr" → "start" (cost 1).
///
/// Uses a stack-allocated 256×256 matrix (64 KB). Inputs longer than 255
/// characters are truncated for the comparison.
pub fn levenshteinDistance(a: []const u8, b: []const u8) usize {
    const max_len = 255;
    const m = @min(a.len, max_len);
    const n = @min(b.len, max_len);

    if (m == 0) return b.len;
    if (n == 0) return a.len;

    // Two extra rows suffice for OSA (we need row i-2, i-1, i).
    // Use a small 3-row rolling buffer to keep stack usage low.
    var rows: [3][256]usize = undefined;

    // row index helpers: cur, prev, prev2
    // rows[(i+0)%3] = current row i
    // rows[(i+2)%3] = row i-1
    // rows[(i+1)%3] = row i-2

    // Initialize row 0 (empty prefix of a vs b[0..j])
    for (0..n + 1) |j| rows[0][j] = j;
    // Initialize row 1 (a[0..1] vs b[0..j])
    rows[1][0] = 1;
    for (1..n + 1) |j| {
        const cost: usize = if (a[0] == b[j - 1]) 0 else 1;
        const sub = rows[0][j - 1] + cost;
        const del = rows[0][j] + 1;
        const ins = rows[1][j - 1] + 1;
        rows[1][j] = @min(sub, @min(del, ins));
    }

    var i: usize = 2;
    while (i <= m) : (i += 1) {
        const cur = i % 3;
        const pr1 = (i + 2) % 3; // i-1
        const pr2 = (i + 1) % 3; // i-2

        rows[cur][0] = i;
        for (1..n + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            const sub = rows[pr1][j - 1] + cost;
            const del = rows[pr1][j] + 1;
            const ins = rows[cur][j - 1] + 1;
            var d = @min(sub, @min(del, ins));
            // OSA: adjacent transposition
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) {
                d = @min(d, rows[pr2][j - 2] + 1);
            }
            rows[cur][j] = d;
        }
    }

    return rows[m % 3][n];
}

/// Return the candidate from `candidates` whose edit distance to `input` is
/// smallest and at most `threshold`. Returns null if no candidate qualifies.
pub fn findClosest(input: []const u8, candidates: []const []const u8, threshold: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = threshold + 1;

    for (candidates) |c| {
        const d = levenshteinDistance(input, c);
        if (d < best_dist) {
            best_dist = d;
            best = c;
        }
    }

    return best;
}

// ---------------------------------------------------------------------------
// Part 3: Help text functions
// ---------------------------------------------------------------------------

pub fn printRootHelp() void {
    const f = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("\n{s}kite{s} — AI Coding Assistant Remote Controller\n\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("{s}Usage:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite{s} <command> [options]\n\n", .{ code(.green), code(.reset) }) catch {};
    out.print("{s}Commands:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}start{s}    Start the kite daemon\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}run{s}      Create a new session in the daemon\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}hook{s}     Handle a Claude Code hook event (internal)\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}setup{s}    Configure kite and show Claude Code hooks config\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}status{s}   Check if kite daemon is running\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}help{s}     Show this help\n", .{ code(.green), code(.reset) }) catch {};
    out.print("\n{s}Run 'kite <command> --help' for more information on a command.{s}\n\n", .{ code(.cyan), code(.reset) }) catch {};
    out.flush() catch {};
}

pub fn printStartHelp() void {
    const f = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("\n{s}kite start{s} — Start the kite daemon\n\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("{s}Description:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  Starts the background daemon that manages Claude Code sessions\n", .{}) catch {};
    out.print("  and connects to the signal server for remote browser access.\n\n", .{}) catch {};
    out.print("{s}Usage:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite start{s} [options]\n\n", .{ code(.green), code(.reset) }) catch {};
    out.print("{s}Options:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}--no-auth{s}           Disable authentication (development only)\n", .{ code(.yellow), code(.reset) }) catch {};
    out.print("  {s}--signal-url{s} <URL>  Signal server URL (overrides config file)\n", .{ code(.yellow), code(.reset) }) catch {};
    out.print("\n{s}Examples:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite start{s}\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}kite start{s} --signal-url wss://my-relay.example.com/remote\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}kite start{s} --no-auth\n\n", .{ code(.green), code(.reset) }) catch {};
    out.flush() catch {};
}

pub fn printRunHelp() void {
    const f = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("\n{s}kite run{s} — Create a new session in the daemon\n\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("{s}Description:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  Connects to the running kite daemon, creates a new terminal session,\n", .{}) catch {};
    out.print("  and attaches your local terminal to it.\n\n", .{}) catch {};
    out.print("{s}Usage:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite run{s} [options]\n\n", .{ code(.green), code(.reset) }) catch {};
    out.print("{s}Options:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}--cmd{s} <CMD>     Command to run (default: claude)\n", .{ code(.yellow), code(.reset) }) catch {};
    out.print("  {s}--attach{s} <ID>  Attach to existing session instead of creating new one\n", .{ code(.yellow), code(.reset) }) catch {};
    out.print("\n{s}Examples:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite run{s}\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}kite run{s} --cmd bash\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}kite run{s} --attach 2\n\n", .{ code(.green), code(.reset) }) catch {};
    out.flush() catch {};
}

pub fn printSetupHelp() void {
    const f = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("\n{s}kite setup{s} — Configure kite\n\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("{s}Description:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  Saves kite configuration and prints the Claude Code hooks snippet\n", .{}) catch {};
    out.print("  to add to ~/.claude/settings.json or .claude/settings.json.\n\n", .{}) catch {};
    out.print("{s}Usage:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite setup{s} [options]\n\n", .{ code(.green), code(.reset) }) catch {};
    out.print("{s}Options:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}--signal-url{s} <URL>  Signal server URL\n", .{ code(.yellow), code(.reset) }) catch {};
    out.print("                       (default: wss://kite.fun.dev/remote)\n", .{}) catch {};
    out.print("\n{s}Examples:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite setup{s}\n", .{ code(.green), code(.reset) }) catch {};
    out.print("  {s}kite setup{s} --signal-url wss://my-relay.example.com/remote\n\n", .{ code(.green), code(.reset) }) catch {};
    out.flush() catch {};
}

pub fn printStatusHelp() void {
    const f = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("\n{s}kite status{s} — Check daemon status\n\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("{s}Description:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  Shows whether the kite daemon is running and displays the current\n", .{}) catch {};
    out.print("  pairing code and QR code for connecting a browser.\n\n", .{}) catch {};
    out.print("{s}Usage:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite status{s}\n\n", .{ code(.green), code(.reset) }) catch {};
    out.flush() catch {};
}

pub fn printHookHelp() void {
    const f = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("\n{s}kite hook{s} — Handle a Claude Code hook event\n\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("{s}Description:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  Internal command called by Claude Code hook scripts. Reads JSON from\n", .{}) catch {};
    out.print("  stdin, forwards it to the kite daemon via Unix socket, and writes\n", .{}) catch {};
    out.print("  the hook response to stdout.\n\n", .{}) catch {};
    out.print("  {s}Note:{s} This command is intended for internal use by the kite hooks\n", .{ code(.cyan), code(.reset) }) catch {};
    out.print("  configuration. You do not need to call it directly.\n\n", .{}) catch {};
    out.print("{s}Usage:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}kite hook{s} --event <EventName>\n\n", .{ code(.green), code(.reset) }) catch {};
    out.print("{s}Options:{s}\n", .{ code(.bold), code(.reset) }) catch {};
    out.print("  {s}--event{s} <Name>  Hook event name (e.g. PreToolUse, PostToolUse)\n\n", .{ code(.yellow), code(.reset) }) catch {};
    out.flush() catch {};
}

// ---------------------------------------------------------------------------
// Part 4: Error message functions
// ---------------------------------------------------------------------------

/// All known top-level command names — exported so callers can pass to findClosest.
pub const command_names = [_][]const u8{ "start", "run", "hook", "setup", "status", "help" };

/// Print "Unknown command" error with optional "Did you mean" suggestion.
pub fn printUnknownCommand(input: []const u8) void {
    const f = std.fs.File.stderr();
    var buf: [1024]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("Unknown command: '{s}'.", .{input}) catch {};

    const suggestion = findClosest(input, &command_names, 2);
    if (suggestion) |s| {
        out.print(" Did you mean '{s}'?", .{s}) catch {};
    }

    out.print("\nRun 'kite help' for a list of available commands.\n", .{}) catch {};
    out.flush() catch {};
}

/// Print "Unknown option" error with optional "Did you mean" suggestion.
pub fn printUnknownOption(option: []const u8, known_options: []const []const u8, command: []const u8) void {
    const f = std.fs.File.stderr();
    var buf: [1024]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("Unknown option: '--{s}'.", .{option}) catch {};

    // Strip leading "--" from input before fuzzy matching against bare names
    const suggestion = findClosest(option, known_options, 2);
    if (suggestion) |s| {
        out.print(" Did you mean '--{s}'?", .{s}) catch {};
    }

    out.print("\nRun 'kite {s} --help' for available options.\n", .{command}) catch {};
    out.flush() catch {};
}

/// Print "Missing required option" error.
pub fn printMissingOption(option: []const u8, command: []const u8, usage: []const u8) void {
    const f = std.fs.File.stderr();
    var buf: [1024]u8 = undefined;
    var w = f.writer(&buf);
    const out = &w.interface;

    out.print("Missing required option: --{s}\n", .{option}) catch {};
    out.print("Usage: {s}\n", .{usage}) catch {};
    out.print("Run 'kite {s} --help' for more information.\n", .{command}) catch {};
    out.flush() catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "levenshtein identical" {
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("start", "start"));
}

test "levenshtein one typo" {
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("star", "start"));
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("statr", "start"));
}

test "levenshtein two edits" {
    // "strt" needs one insertion ('a') to become "start": correct OSA distance is 1.
    // A two-edit example: "stt" → "start" requires inserting 'a' and 'r' = 2.
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("strt", "start"));
    try std.testing.expectEqual(@as(usize, 2), levenshteinDistance("stt", "start"));
}

test "levenshtein empty" {
    try std.testing.expectEqual(@as(usize, 5), levenshteinDistance("", "start"));
    try std.testing.expectEqual(@as(usize, 5), levenshteinDistance("start", ""));
}

test "findClosest match" {
    const cmds = [_][]const u8{ "start", "run", "hook", "setup", "status", "help" };
    try std.testing.expectEqualStrings("start", findClosest("star", &cmds, 2).?);
    try std.testing.expectEqualStrings("start", findClosest("strat", &cmds, 2).?);
    try std.testing.expectEqualStrings("status", findClosest("statu", &cmds, 2).?);
    try std.testing.expect(findClosest("xyzzy", &cmds, 2) == null);
}
