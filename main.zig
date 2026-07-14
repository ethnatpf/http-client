const std = @import("std");
const Response = @import("src/response.zig");
const Request = @import("src/request.zig");

pub fn main(init: std.process.Init) !void {
    const stream = try Request.fetch(init.io);
    defer stream.close(init.io);

    // Read the response
    // TODO: This could be optimized
    var reader_buffer: [4096]u8 = undefined;

    var stream_reader = stream.reader(init.io, &reader_buffer);
    const reader = &stream_reader.interface;

    const response = try Response.parse(reader, init.gpa);

    std.debug.print("Response: {s}", .{response});
    defer init.gpa.free(response);
}
