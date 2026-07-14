const std = @import("std");

const ParseError = error{EmptyResponse};

/// Parse an HTTP response from a reader.
pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    var response: ?[]u8 = null;

    while (true) {
        const currSlice: ?[]u8 = reader.peek(1) catch |err| switch (err) {
            error.EndOfStream => null,
            else => return err,
        };

        if (currSlice == null) {
            break;
        } else {
            // Increment the current position
            reader.toss(1);
        }

        if (currSlice) |definedCurrentSlice| {
            if (response) |definedResponse| {
                defer allocator.free(definedResponse);
                response = try std.mem.concat(allocator, u8, &[_][]const u8{ definedResponse, definedCurrentSlice });
            } else {
                response = try allocator.dupe(u8, definedCurrentSlice);
            }
        }
    }

    if (response) |definedResponse| {
        return definedResponse;
    } else {
        std.debug.print("Unexpected empty response", .{});
        return ParseError.EmptyResponse;
    }
}
