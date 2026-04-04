const std = @import("std");
const crypto = std.crypto;

pub const Auth = struct {
    secret: [32]u8,
    setup_token: [32]u8,
    session_token: ?[64]u8 = null,
    setup_token_used: bool = false,
    setup_token_created: i64,
    session_token_created: i64 = 0,
    disabled: bool = false,

    const setup_token_ttl = 300; // 5 minutes
    const session_token_ttl = 86400; // 24 hours

    pub fn init() Auth {
        var secret: [32]u8 = undefined;
        crypto.random.bytes(&secret);
        var setup: [32]u8 = undefined;
        crypto.random.bytes(&setup);
        return .{
            .secret = secret,
            .setup_token = setup,
            .setup_token_created = std.time.timestamp(),
        };
    }

    pub fn getSetupTokenHex(self: *const Auth) [64]u8 {
        return std.fmt.bytesToHex(self.setup_token, .lower);
    }

    pub fn getSecretHex(self: *const Auth) [64]u8 {
        return std.fmt.bytesToHex(self.secret, .lower);
    }

    pub fn validateSetupToken(self: *Auth, token_hex: []const u8) ?[128]u8 {
        if (self.setup_token_used) return null;
        if (std.time.timestamp() - self.setup_token_created > setup_token_ttl) return null;

        const expected = self.getSetupTokenHex();
        if (!std.mem.eql(u8, token_hex, &expected)) return null;

        self.setup_token_used = true;

        // Generate session token
        var session_bytes: [64]u8 = undefined;
        crypto.random.bytes(&session_bytes);
        self.session_token = session_bytes;
        self.session_token_created = std.time.timestamp();
        return std.fmt.bytesToHex(session_bytes, .lower);
    }

    pub fn validateSessionToken(self: *const Auth, token_hex: []const u8) bool {
        if (self.disabled) return true;
        if (self.session_token) |session| {
            if (std.time.timestamp() - self.session_token_created > session_token_ttl) return false;
            const expected = std.fmt.bytesToHex(session, .lower);
            return std.mem.eql(u8, token_hex, &expected);
        }
        return false;
    }

    pub fn refreshSessionToken(self: *Auth) ?[128]u8 {
        if (self.session_token == null) return null;
        // Generate new token
        var new_bytes: [64]u8 = undefined;
        crypto.random.bytes(&new_bytes);
        self.session_token = new_bytes;
        self.session_token_created = std.time.timestamp();
        return std.fmt.bytesToHex(new_bytes, .lower);
    }
};

pub fn generatePairingCode() [6]u8 {
    const charset = "abcdefghijklmnopqrstuvwxyz0123456789";
    var raw: [6]u8 = undefined;
    crypto.random.bytes(&raw);
    var code: [6]u8 = undefined;
    for (raw, 0..) |b, i| {
        code[i] = charset[b % charset.len];
    }
    return code;
}

pub fn renderQrCode(writer: anytype, signal_url: []const u8, pairing_code: []const u8, setup_token_hex: []const u8) !void {
    try writer.print("\n", .{});
    try writer.print("  Scan QR code or open this URL on your phone:\n", .{});
    try writer.print("  {s}/#/pair/{s}:{s}\n\n", .{ signal_url, pairing_code, setup_token_hex });

    // Simple ASCII art box around the URL for visibility
    const border = "+" ++ "-" ** 60 ++ "+";
    try writer.print("  {s}\n", .{border});
    try writer.print("  | {s}/#/pair/{s}:{s}\n", .{ signal_url, pairing_code, setup_token_hex });
    try writer.print("  {s}\n\n", .{border});

    try writer.print("  Pairing code: {s}\n\n", .{pairing_code});

    try writer.print("  Tip: pipe the URL to 'qrencode -t UTF8' for a scannable QR code.\n\n", .{});
}

test "auth token flow" {
    var auth = Auth.init();
    const setup_hex = auth.getSetupTokenHex();

    // Valid setup token exchange
    const session = auth.validateSetupToken(&setup_hex);
    try std.testing.expect(session != null);

    // Setup token is single-use
    const second = auth.validateSetupToken(&setup_hex);
    try std.testing.expect(second == null);

    // Session token validation
    if (session) |s| {
        try std.testing.expect(auth.validateSessionToken(&s));
    }
}

test "pairing code generation" {
    const code1 = generatePairingCode();
    const code2 = generatePairingCode();

    // Verify length is 6
    try std.testing.expectEqual(@as(usize, 6), code1.len);
    try std.testing.expectEqual(@as(usize, 6), code2.len);

    // Verify two codes are (almost certainly) different
    try std.testing.expect(!std.mem.eql(u8, &code1, &code2));

    // Verify all chars are lowercase alphanumeric
    for (code1) |c| {
        try std.testing.expect((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'));
    }
    for (code2) |c| {
        try std.testing.expect((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'));
    }
}
