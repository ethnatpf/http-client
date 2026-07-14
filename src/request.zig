const std = @import("std");

/// Make an HTTP request to an endpoint, and return the stream. Don't forget to close the stream.
///
pub fn fetch(io: std.Io) !std.Io.net.Stream {
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
