const std = @import("std");

const ParseError = error{ EmptyResponse, MalformedResponse };

const HTTPHeader = struct { name: []const u8, value: []const u8 };

const Response = struct { status_code: u8, status_message: []const u8, headers: std.ArrayList(HTTPHeader), data: []u8 };

pub fn findHeader(headers: []const HTTPHeader, name: []const u8) ?*const HTTPHeader {
    for (headers) |*header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header;
        }
    }
    return null;
}

/// Parse an HTTP response from a reader.
/// Headers and data must be unallocated
pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !Response {
    const status_line = try reader.takeDelimiterExclusive('\n');
    // takeDelimiterExclusive move the seek to the delimiter, so we need to increment it by one to prevent from reading it again on the next takeDelimiterExclusive
    reader.toss(1);
    var status_line_it = std.mem.splitScalar(u8, status_line, ' ');
    // Skip the http version
    _ = status_line_it.next();
    const status_code = status_line_it.next();
    const status_message = status_line_it.rest();

    if (status_code == null) {
        return ParseError.MalformedResponse;
    }

    var headers: std.ArrayList(HTTPHeader) = .empty;
    errdefer headers.deinit(allocator);

    // Parse the headers
    while (true) {
        const next_line = try reader.takeDelimiterExclusive('\n');
        reader.toss(1);

        // If there is two \r\n in a row, we reached the end of the headers.
        if (std.mem.eql(u8, try reader.peek(2), "\r\n")) {
            reader.toss(2);
            break;
        }

        var splitted_header = std.mem.splitScalar(u8, next_line, ':');
        const header_name = splitted_header.next();
        const header_value = splitted_header.next();

        if (header_name == null or header_value == null) {
            std.debug.print("Malformed HTTP header inside the response \"{s}\"\n", .{next_line});
            return ParseError.MalformedResponse;
        }

        const header = HTTPHeader{ .name = header_name.?, .value = std.mem.trim(u8, header_value.?, " \r") };

        try headers.append(allocator, header);
    }

    const content_length_header = findHeader(headers.items, "Content-Length");
    if (content_length_header == null) {
        std.debug.print("Missing content-length header\n", .{});
        return ParseError.MalformedResponse;
    }

    const content_length = try std.fmt.parseInt(u64, content_length_header.?.value, 10);

    const data = try allocator.alloc(u8, content_length);
    errdefer allocator.free(data);
    // readSliceAll will fill the data buffer based on it's length. Using take wouldn't work as it would require the internal reader buffer to be the size of the response,
    // which wouldn't work as it's size is allocated at compile time.
    try reader.readSliceAll(data);

    return Response{ .status_code = try std.fmt.parseInt(u8, status_code.?, 10), .status_message = status_message, .headers = headers, .data = data };
}
