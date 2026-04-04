const std = @import("std");

pub const ParsedPrompt = struct {
    summary: []const u8,
    options: []const []const u8,
};

/// 从 Claude Code 的 Stop hook payload 中提取提示摘要。
/// stop_reason 为 "end_turn" 表示 Claude 完成处理等待下一轮输入。
pub fn isWaitingForInput(stop_reason: []const u8) bool {
    return std.mem.eql(u8, stop_reason, "end_turn");
}

/// 从终端输出的最后几行中提取选项。
/// 识别模式如：(y)es/(n)o、[Y/n]、1. xxx 2. xxx 等。
pub fn extractOptions(allocator: std.mem.Allocator, terminal_tail: []const u8) ![]const []const u8 {
    var options: std.ArrayList([]const u8) = .empty;
    errdefer options.deinit(allocator);

    // 匹配 (y)es/(n)o 风格
    if (containsYesNo(terminal_tail)) {
        try options.append(allocator, "Yes");
        try options.append(allocator, "No");
        return options.toOwnedSlice(allocator);
    }

    // 匹配数字列表: "1. xxx\n2. xxx"
    var lines = std.mem.splitScalar(u8, terminal_tail, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len >= 3 and trimmed[0] >= '1' and trimmed[0] <= '9' and (trimmed[1] == '.' or trimmed[1] == ')')) {
            const option_text = std.mem.trim(u8, trimmed[2..], " ");
            if (option_text.len > 0) {
                try options.append(allocator, option_text);
            }
        }
    }

    return options.toOwnedSlice(allocator);
}

/// 从终端输出最后部分提取摘要（最后的非空行，最多 500 字节）
pub fn extractSummary(terminal_tail: []const u8) []const u8 {
    if (terminal_tail.len == 0) return "";

    var end = terminal_tail.len;
    while (end > 0 and (terminal_tail[end - 1] == '\n' or terminal_tail[end - 1] == '\r' or terminal_tail[end - 1] == ' ')) {
        end -= 1;
    }
    if (end == 0) return "";

    const max_len: usize = 500;
    const start = if (end > max_len) end - max_len else 0;

    return terminal_tail[start..end];
}

fn containsYesNo(text: []const u8) bool {
    const patterns = [_][]const u8{
        "(y/n)", "(Y/n)", "(y/N)", "[y/n]", "[Y/n]", "[y/N]", "(yes/no)", "Yes/No",
    };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, text, pattern) != null) return true;
    }
    return false;
}

test "isWaitingForInput" {
    try std.testing.expect(isWaitingForInput("end_turn"));
    try std.testing.expect(!isWaitingForInput("error"));
    try std.testing.expect(!isWaitingForInput(""));
}

test "extractOptions yes/no" {
    const allocator = std.testing.allocator;
    const options = try extractOptions(allocator, "Do you want to continue? (y/n)");
    defer allocator.free(options);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqualStrings("Yes", options[0]);
    try std.testing.expectEqualStrings("No", options[1]);
}

test "extractOptions numbered list" {
    const allocator = std.testing.allocator;
    const text = "Choose an option:\n1. Create new file\n2. Edit existing\n3. Delete";
    const options = try extractOptions(allocator, text);
    defer allocator.free(options);
    try std.testing.expectEqual(@as(usize, 3), options.len);
    try std.testing.expectEqualStrings("Create new file", options[0]);
    try std.testing.expectEqualStrings("Edit existing", options[1]);
    try std.testing.expectEqualStrings("Delete", options[2]);
}

test "extractOptions no options" {
    const allocator = std.testing.allocator;
    const options = try extractOptions(allocator, "Just some regular text output");
    defer allocator.free(options);
    try std.testing.expectEqual(@as(usize, 0), options.len);
}

test "extractSummary" {
    const summary = extractSummary("Hello\nWhat would you like to do?\n\n");
    try std.testing.expectEqualStrings("Hello\nWhat would you like to do?", summary);
}

test "extractSummary empty" {
    const summary = extractSummary("");
    try std.testing.expectEqualStrings("", summary);
}
