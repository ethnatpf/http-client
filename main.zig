const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8000);

    const stream = try std.Io.net.IpAddress.connect(&address, init.io, .{ .protocol = .tcp, .mode = .stream });
    defer stream.close(init.io);

    // Send the request
    // TODO: Allow to customize the request with args
    const request =
        \\GET / HTTP/1.1
        \\Host: 127.0.0.1:8000
        \\
        \\
    ;

    var writer_buffer: [2048]u8 = undefined;
    var stream_writer = stream.writer(init.io, &writer_buffer);
    var writer = &stream_writer.interface;

    _ = try writer.write(request);
    // As we use a buffer for the writer, we need to flush to send. Without a flush, it would wait until the buffer is full to send it.
    try writer.flush();

    // Read the response
    var reader_buffer: [4096]u8 = undefined;

    var stream_reader = stream.reader(init.io, &reader_buffer);
    var reader = &stream_reader.interface;

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
                defer init.gpa.free(definedResponse);
                response = try std.mem.concat(init.gpa, u8, &[_][]const u8{ definedResponse, definedCurrentSlice });
            } else {
                response = try init.gpa.dupe(u8, definedCurrentSlice);
            }
        }
    }

    if (response) |definedResponse| {
        // Free the last buffer
        defer init.gpa.free(definedResponse);

        std.debug.print("{s}", .{definedResponse});
    } else {
        std.debug.print("Unexpected empty response", .{});
    }
}
