const std = @import("std");
const dns = @import("dns.zig");

pub const FetchError = error{ UnsupportedTarget, InvalidTarget, InvalidScheme };

const ParseLiteralError = std.Io.net.IpAddress.ParseLiteralError;

/// Make an HTTP request to an endpoint, and return the stream. Don't forget to close the stream.
pub fn fetch(io: std.Io, allocator: std.mem.Allocator, target: []const u8) !std.Io.net.Stream {
    var parsedIp = std.Io.net.IpAddress.parseLiteral(target) catch |err| switch (err) {
        ParseLiteralError.InvalidAddress => null,
        ParseLiteralError.InvalidPort => unreachable,
    };

    var final_host: ?[]const u8 = null;
    var final_path: []const u8 = "/";

    // If null, assume it's an url
    if (parsedIp == null) {
        // Resolve the dns and reassigned parsedIp
        // TODO: Handle errors properly here
        const parsedUri = try std.Uri.parse(target);

        if (parsedUri.host == null) {
            std.debug.print("Unable to extract the host out of this target.", .{});
            return FetchError.InvalidTarget;
        }
        final_host = parsedUri.host.?.percent_encoded;
        final_path = parsedUri.path.percent_encoded;

        std.debug.print("Resolving the host...\n", .{});
        parsedIp = try dns.resolveHost(io, allocator, final_host.?);

        // Set the port based on the scheme
        const port: u16 = if (std.mem.eql(u8, parsedUri.scheme, "https")) 443 else if (std.mem.eql(u8, parsedUri.scheme, "http")) 80 else return FetchError.InvalidScheme;
        parsedIp.?.setPort(port);

        std.debug.print("Resolved to {f}\n", .{parsedIp.?});
    }

    if (parsedIp != null and std.meta.activeTag(parsedIp.?) == .ip6) {
        std.debug.print("ipv6 is not supported\n", .{});
        return FetchError.UnsupportedTarget;
    }

    if (parsedIp == null) {
        // We were not able to parse the target.
        return FetchError.InvalidTarget;
    }

    if (final_host == null) {
        final_host = try std.fmt.allocPrint(allocator, "{f}", .{parsedIp.?});
        defer allocator.free(final_host.?);
    }

    std.debug.print("Connecting to the stream\n", .{});
    const stream = try std.Io.net.IpAddress.connect(&parsedIp.?, io, .{ .protocol = .tcp, .mode = .stream });

    std.debug.print("Connected. Will send the request\n", .{});
    // Send the request
    const request = try std.fmt.allocPrint(allocator,
        \\GET {s} HTTP/1.1
        \\Host: {s}
        \\
        \\
    , .{ final_path, final_host.? });
    defer allocator.free(request);

    std.debug.print("Request: {s}\n", .{request});

    var writer_buffer: [2048]u8 = undefined;
    var stream_writer = stream.writer(io, &writer_buffer);
    var writer = &stream_writer.interface;

    _ = try writer.write(request);
    // As we use a buffer for the writer, we need to flush to send. Without a flush, it would wait until the buffer is full to send it.
    try writer.flush();

    return stream;
}
