const std = @import("std");
const crypto = std.crypto;

pub const Auth = struct {
    secret: [32]u8,
    setup_secret_hex: [64]u8 = .{0} ** 64,
    session_token: ?[64]u8 = null,
    session_token_created: i64 = 0,
    disabled: bool = false,

    const session_token_ttl = 86400; // 24 hours

    pub fn init() Auth {
        var secret: [32]u8 = undefined;
        crypto.random.bytes(&secret);
        return .{
            .secret = secret,
        };
    }

    pub fn getSecretHex(self: *const Auth) [64]u8 {
        return std.fmt.bytesToHex(self.secret, .lower);
    }

    pub fn validateSetupSecret(self: *Auth, secret_hex: []const u8) ?[128]u8 {
        if (self.setup_secret_hex.len == 0) return null;
        if (!std.mem.eql(u8, secret_hex, &self.setup_secret_hex)) return null;

        // Generate a new session token
        var session_bytes: [64]u8 = undefined;
        crypto.random.bytes(&session_bytes);
        self.session_token = session_bytes;
        self.session_token_created = std.time.timestamp();
        return std.fmt.bytesToHex(session_bytes, .lower);
    }

    pub fn setSetupSecret(self: *Auth, hex: []const u8) void {
        if (hex.len == 64) {
            @memcpy(&self.setup_secret_hex, hex[0..64]);
        }
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

test "auth token flow" {
    var auth = Auth.init();

    // Set a setup secret
    var secret_bytes: [32]u8 = undefined;
    crypto.random.bytes(&secret_bytes);
    const secret_hex = std.fmt.bytesToHex(secret_bytes, .lower);
    auth.setSetupSecret(&secret_hex);

    // Valid setup secret exchange
    const session = auth.validateSetupSecret(&secret_hex);
    try std.testing.expect(session != null);

    // Setup secret is reusable (not single-use)
    const second = auth.validateSetupSecret(&secret_hex);
    try std.testing.expect(second != null);

    // Session token validation (use the latest session token)
    if (second) |s| {
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
