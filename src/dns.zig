const std = @import("std");

pub fn parseDNS(host: []const u8) ?std.Io.net.IpAddress {
    _ = host;
    return std.Io.net.IpAddress.parseLiteral("127.0.0.1") catch null;
}
