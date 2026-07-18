const std = @import("std");

pub fn resolveHost(io: std.Io, allocator: std.mem.Allocator, host: []const u8) !?std.Io.net.IpAddress {
    // Cloudflare DNS server
    const address = try std.Io.net.IpAddress.parse("1.1.1.1", 53);

    var stream = try std.Io.net.IpAddress.connect(&address, io, .{
        .protocol = .udp,
        .mode = .dgram,
    });
    defer stream.close(io);

    var stream_writer = stream.writer(io, &.{});
    var writer = &stream_writer.interface;

    const request_header: [6]u16 = .{
        // ID of the request (can be anything)
        32,
        // flags - only enable recursivity
        0b0_0000_0_0_1_0_000_0000,
        // question count
        1,
        // answer count (this is a query, so 0)
        0,
        // authority count
        0,
        // additional count
        0,
    };

    // ArrayList is a dynamic length array (similar to a js array)
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);

    var labelsIterator = std.mem.splitScalar(u8, host, '.');
    while (labelsIterator.next()) |label| {
        try labels.append(allocator, label);
    }

    // Length of the question in bytes (includes type and class 4 bytes + the 0 sentinel last byte)
    var question_length: usize = 5;

    for (labels.items) |label| {
        // The +1 is for the length byte of each label
        question_length += 1 + label.len;
    }

    const request_question = try allocator.alloc(u8, question_length);
    defer allocator.free(request_question);

    var question_index: usize = 0;
    for (labels.items) |label| {
        request_question[question_index] = @intCast(label.len);
        @memcpy(request_question[question_index + 1 .. question_index + 1 + label.len], label);
        question_index += 1 + label.len;
    }

    // Add the sentinel at the end of the labels
    request_question[question_index] = 0;
    // Add the query type (hard coded A record in our case to request an IPv4 address)
    // Note: byte order must be in big endian, so most significant byte first
    @memcpy(request_question[question_index + 1 .. question_index + 3], &[2]u8{ 0, 1 });
    // Add the query class (1 corresponds to internet)
    @memcpy(request_question[question_index + 3 ..], &[2]u8{ 0, 1 });

    var header_bytes: [12]u8 = undefined;

    // Transform the header u16 array to an u8 array
    for (request_header, 0..) |value, i| {
        // The syntax header_bytes[i * 2 ..][0..2] is to get a slice of exactly 2 elements. Is allows zig to know the size of the slice at compile time.
        // .big is to force Big-endian, which means that the most significant byte will be written first, ignoring the cpu default endian preference.
        std.mem.writeInt(u16, header_bytes[i * 2 ..][0..2], value, .big);
    }

    const dns_query = try std.mem.concat(allocator, u8, &.{ &header_bytes, request_question });

    _ = try writer.write(dns_query);

    var stream_reader = stream.reader(io, &.{});
    var reader = &stream_reader.interface;

    var response_buffer: [1][]u8 = undefined;

    std.debug.print("Read the DNS reader buffer\n", .{});
    // TODO: Implement timeout/retry if we don't get any response.
    _ = try reader.readVec(&response_buffer);
    std.debug.print("DNS response: {s}\n", .{response_buffer[0]});

    return std.Io.net.IpAddress.parseLiteral("127.0.0.1") catch null;
}
