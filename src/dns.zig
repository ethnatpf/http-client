const std = @import("std");
const utils = @import("utils.zig");

const DNSError = error{ EmptyResponse, InvalidHeaders, FormatError, ServerError, NonExistentDomain, UnsupportedAnswerType };

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

/// Parse the labels section of a DNS payload
/// Returns the last index of the labels (sentinel index or compression pointer last index)
fn getLabelsEndIndex(payload: []u8, start_index: usize) usize {
    var cursor: usize = start_index;

    // Find the end of the questions section
    // A label can be compressed with a compression pointer. A compression pointer always has 11 as the most significant bytes, and it spans on 2 bytes.
    if (payload[start_index] == 0xc0) {
        cursor += 1;
        // A compression pointer indicates the end of the labels section. We don't need to follow it.
    } else {
        cursor = std.mem.findScalarPos(u8, payload, start_index, 0).?;
    }

    return cursor;
}

const AnswerType = enum { A, NS, CNAME, MX, TXT, AAAA };

const DNSResponse = struct { address: []u8, type: AnswerType, ttl: u32 };

/// Parse a DNS response and returns the IP if its a success or an error if not.
/// Question length is in bytes
/// Returns a DNSResponse - the address has allocated memory and must be unallocated
fn parseDNSResponse(allocator: std.mem.Allocator, response: []u8) !DNSResponse {
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
        switch (headers.flags.rcode) {
            1 => return DNSError.FormatError,
            2 => return DNSError.ServerError,
            3 => return DNSError.NonExistentDomain,
            else => unreachable,
        }
    }

    // Assume only one question and answer as we only sent one.
    if (headers.question_count != 1 or headers.answer_count != 1) {
        unreachable;
    }

    var cursor = getLabelsEndIndex(response, 12);
    // Add the question type and class bytes (2 each) - result is the index of the end of the question section
    cursor += 5;

    // Move the cursor forward to the end of the answer labels section
    cursor = getLabelsEndIndex(response, cursor);

    const answer_type: AnswerType = switch (std.mem.readInt(u16, response[cursor + 1 .. cursor + 3][0..2], .big)) {
        1 => AnswerType.A,
        2 => AnswerType.NS,
        5 => AnswerType.CNAME,
        15 => AnswerType.MX,
        16 => AnswerType.TXT,
        28 => AnswerType.AAAA,
        else => unreachable,
    };

    if (answer_type != AnswerType.A) {
        std.debug.print("Unsupported DNS answer type {}\n", .{answer_type});
        return DNSError.UnsupportedAnswerType;
    }

    // Skip the answer type and class bytes
    cursor += 5;

    const ttl = std.mem.readInt(u32, response[cursor .. cursor + 4][0..4], .big);
    cursor += 4;

    const rd_length = std.mem.readInt(u16, response[cursor .. cursor + 2][0..2], .big);
    cursor += 2;

    const address = response[cursor .. cursor + rd_length];

    const final_address_length = length: {
        var length: usize = 0;
        for (address, 0..) |component, idx| {
            length += utils.decimalLength(component);
            if (idx < address.len - 1) {
                // Add 1 for the '.' separator
                length += 1;
            }
        }

        break :length length;
    };

    const final_address_buf = try allocator.alloc(u8, final_address_length);
    errdefer allocator.free(final_address_buf);

    var address_buf_idx: usize = 0;
    for (address) |component| {
        const component_length = utils.decimalLength(component);
        _ = try std.fmt.bufPrint(final_address_buf[address_buf_idx .. address_buf_idx + component_length], "{d}", .{component});

        if (address_buf_idx + component_length < final_address_length) {
            final_address_buf[address_buf_idx + component_length] = '.';
        }
        address_buf_idx += component_length + 1;
    }

    return DNSResponse{ .address = final_address_buf, .ttl = ttl, .type = answer_type };
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

    // TODO: Implement timeout/retry if we don't get any response.
    _ = try reader.readVec(&response_data);
    const response = try parseDNSResponse(allocator, response_data[0]);
    defer allocator.free(response.address);

    return std.Io.net.IpAddress.parseLiteral(response.address) catch null;
}
