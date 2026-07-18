const std = @import("std");
const dns = @import("dns.zig");

pub const FetchError = error{ UnsupportedTarget, InvalidTarget };

/// Make an HTTP request to an endpoint, and return the stream. Don't forget to close the stream.
pub fn fetch(io: std.Io, allocator: std.mem.Allocator, target: []const u8) !std.Io.net.Stream {
    var parsedIp = std.Io.net.IpAddress.parseLiteral(target) catch null;

    // If null, assume it's an url
    if (parsedIp == null) {
        // Resolve the dns and reassigned parsedIp
        const parsedUri = try std.Uri.parse(target);

        if (parsedUri.host == null) {
            std.debug.print("Unable to extract the host out of this target.", .{});
            return FetchError.InvalidTarget;
        }
        const host = parsedUri.host.?.percent_encoded;

        std.debug.print("Host: {s}\n", .{host});

        std.debug.print("Resolving the host...\n", .{});
        parsedIp = try dns.resolveHost(io, allocator, host);
    }

    if (parsedIp != null and std.meta.activeTag(parsedIp.?) == .ip6) {
        std.debug.print("ipv6 is not supported\n", .{});
        return FetchError.UnsupportedTarget;
    }

    if (parsedIp == null) {
        // We were not able to parse the target.
        return FetchError.InvalidTarget;
    }

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8000);

    const stream = try std.Io.net.IpAddress.connect(&address, io, .{ .protocol = .tcp, .mode = .stream });

    // Send the request
    // TODO: Allow to customize the request with args
    const request =
        \\GET / HTTP/1.1
        \\Host: 127.0.0.1:8000
        \\
        \\
    ;

    var writer_buffer: [2048]u8 = undefined;
    var stream_writer = stream.writer(io, &writer_buffer);
    var writer = &stream_writer.interface;

    _ = try writer.write(request);
    // As we use a buffer for the writer, we need to flush to send. Without a flush, it would wait until the buffer is full to send it.
    try writer.flush();

    return stream;
}
