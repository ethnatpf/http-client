const std = @import("std");
const Response = @import("src/response.zig");
const Request = @import("src/request.zig");

pub fn main(init: std.process.Init) !void {
    const stream = try Request.fetch(init.io, init.gpa, "http://postman-echo.com/get");
    defer stream.close(init.io);

    // Read the response
    // TODO: This could be optimized
    var reader_buffer: [4096]u8 = undefined;

    var stream_reader = stream.reader(init.io, &reader_buffer);
    const reader = &stream_reader.interface;

    var response = try Response.parse(reader, init.gpa);
    defer response.headers.deinit(init.gpa);
    defer init.gpa.free(response.data);

    std.debug.print("Response:\n Status code: {} Status message: {s}\n Data: {s}\n", .{ response.status_code, response.status_message, response.data });
}
