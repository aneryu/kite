const std = @import("std");
const c = @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("arpa/inet.h");
    @cInclude("netinet/in.h");
});

/// Returns the first non-loopback IPv4 address as a string, or null.
pub fn getLanIp(buf: *[16]u8) ?[]const u8 {
    var ifap: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return null;
    defer c.freeifaddrs(ifap);

    var ifa = ifap;
    while (ifa) |a| : (ifa = a.ifa_next) {
        const sa = a.ifa_addr orelse continue;
        if (sa.*.sa_family != c.AF_INET) continue;
        const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(sa));
        const addr = sin.sin_addr;
        // Skip loopback (127.x.x.x)
        const first_byte: u8 = @truncate(addr.s_addr & 0xFF);
        if (first_byte == 127) continue;
        const result = c.inet_ntop(c.AF_INET, &addr, buf, 16);
        if (result == null) continue;
        // Find length of C string
        var len: usize = 0;
        while (len < 16 and buf[len] != 0) : (len += 1) {}
        return buf[0..len];
    }
    return null;
}
