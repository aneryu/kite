const std = @import("std");
const crypto = std.crypto;

pub const Auth = struct {
    secret: [32]u8,
    setup_token: [32]u8,
    session_token: ?[64]u8 = null,
    setup_token_used: bool = false,
    setup_token_created: i64,

    const setup_token_ttl = 300; // 5 minutes

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
        return std.fmt.bytesToHex(session_bytes, .lower);
    }

    pub fn validateSessionToken(self: *const Auth, token_hex: []const u8) bool {
        if (self.session_token) |session| {
            const expected = std.fmt.bytesToHex(session, .lower);
            return std.mem.eql(u8, token_hex, &expected);
        }
        return false;
    }
};

pub fn renderQrCode(writer: anytype, url: []const u8) !void {
    try writer.print("\n", .{});
    try writer.print("  Scan QR code or open this URL on your phone:\n", .{});
    try writer.print("  {s}\n\n", .{url});

    // Simple ASCII art box around the URL for visibility
    const border = "+" ++ "-" ** 60 ++ "+";
    try writer.print("  {s}\n", .{border});
    try writer.print("  | {s: <58} |\n", .{url});
    try writer.print("  {s}\n\n", .{border});

    // Note: A real QR code renderer would encode the URL into QR matrix.
    // For MVP, we provide the URL directly. Users can use a URL shortener
    // or the terminal output can be piped to a QR code generator.
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
