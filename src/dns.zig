const std = @import("std");

const DNSError = error{ EmptyResponse, InvalidHeaders, FormatError, ServerError, NonExistentDomain };

// A packed struct is in least significant bit first order, so we must "reverse" the fields.
// Note for myself: This has nothing to do with endianness
pub const DNSHeadersFlags = packed struct {
    // Response code
    rcode: u4 = 0,
    cd: u1 = 0,
    ad: u1 = 0,
    // Reserved for future use, always 0
    z: u1 = 0,
    // In a response, indicates if the dns server supports recursion
    ra: u1 = 0,
    // In a query, indicates if we want a recursive query
    rd: u1 = 0,
    // Whether or not the message has been truncated
    tc: u1 = 0,
    // Indicates if the DNS server is authoritative for the queried hostname
    aa: u1 = 0,
    // Op code
    // 0 for standard query
    opcode: u4 = 0,
    // Query (0) or response (1)
    qr: u1,
};

// https://en.wikipedia.org/wiki/Domain_Name_System#DNS_message_format
pub const DNSHeaders = struct {
    // Transaction ID
    id: u16,
    flags: DNSHeadersFlags,
    question_count: u16 = 0,
    answer_count: u16 = 0,
    authority_rr_count: u16 = 0,
    additional_rr_count: u16 = 0,
    fn toBytes(self: DNSHeaders) [12]u8 {
        var header_bytes: [12]u8 = undefined;
        const request_headers = [6]u16{ self.id, @bitCast(self.flags), self.question_count, self.answer_count, self.authority_rr_count, self.additional_rr_count };

        // Transform the header u16 array to an u8 array
        for (request_headers, 0..) |value, i| {
            // The syntax header_bytes[i * 2 ..][0..2] is to get a slice of exactly 2 elements. Is allows zig to know the size of the slice at compile time.
            // .big is to force Big-endian, which means that the most significant byte will be written first, ignoring the cpu default endian preference.
            std.mem.writeInt(u16, header_bytes[i * 2 ..][0..2], value, .big);
        }

        return header_bytes;
    }

    pub fn parseHeaders(headers: [6]u16) !DNSHeaders {
        // We need at least 6 bytes for the headers
        if (headers.len < 6) {
            return DNSError.InvalidHeaders;
        }

        return .{ .id = headers[0], .flags = @bitCast(headers[1]), .question_count = headers[2], .answer_count = headers[3], .authority_rr_count = headers[4], .additional_rr_count = headers[5] };
    }
};

fn buildDNSQuery(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    const request_headers = DNSHeaders{
        // ID of the request (can be anything)
        .id = 32,
        .flags = .{
            // Indicates this is a query
            .qr = 0,
            // It's a recursive query
            .rd = 1,
        },
        .question_count = 1,
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

    const header_bytes = request_headers.toBytes();

    return try std.mem.concat(allocator, u8, &.{ &header_bytes, request_question });
}

/// Parse a DNS response and returns the IP if its a success or an error if not.
/// Question length is in bytes
fn parseDNSResponse(response: []u8) !void {
    if (response.len == 0) {
        return DNSError.EmptyResponse;
    }

    var u16_headers: [6]u16 = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        u16_headers[i] = std.mem.readInt(u16, response[i * 2 .. (i * 2) + 2][0..2], .big);
    }

    const headers = try DNSHeaders.parseHeaders(u16_headers);

    // Handle errors returned by the DNS server
    if (headers.flags.rcode != 0) {
        //std.debug.print("rcode: {any}\n", .{headers.flags.rcode});
        //std.debug.print("headers: {any}\n", .{headers});
        switch (headers.flags.rcode) {
            1 => return DNSError.FormatError,
            2 => return DNSError.ServerError,
            3 => return DNSError.NonExistentDomain,
            else => unreachable,
        }
    }

    std.debug.print("Parsed headers: {any}\n", .{headers});
    // Parse and skip the questions - always start at index 12 (after the headers)
    // The question section is structured like this: 1 byte for the label length, then the label. Repeat for all the labels. A question ends with 0.
    const question_sentinel_idx = std.mem.find(u8, response[12..], "0");
    std.debug.print("Sentinel id: {?any}", .{question_sentinel_idx});

    // TODO: Parse the answer
}

pub fn resolveHost(io: std.Io, allocator: std.mem.Allocator, host: []const u8) !?std.Io.net.IpAddress {
    // 1.1.1.1 is cloudflare DNS server
    const address = try std.Io.net.IpAddress.parse("1.1.1.1", 53);

    var stream = try std.Io.net.IpAddress.connect(&address, io, .{
        .protocol = .udp,
        .mode = .dgram,
    });
    defer stream.close(io);

    var stream_writer = stream.writer(io, &.{});
    var writer = &stream_writer.interface;

    const dns_query = try buildDNSQuery(allocator, host);

    defer allocator.free(dns_query);

    _ = try writer.write(dns_query);

    var stream_reader = stream.reader(io, &.{});
    var reader = &stream_reader.interface;

    var response_buffer: [1024]u8 = undefined;
    // We need to initialize the slice here
    var response_data: [1][]u8 = .{&response_buffer};

    std.debug.print("Read the DNS reader buffer\n", .{});
    // TODO: Implement timeout/retry if we don't get any response.
    _ = try reader.readVec(&response_data);
    try parseDNSResponse(response_data[0]);

    return std.Io.net.IpAddress.parseLiteral("127.0.0.1") catch null;
}
