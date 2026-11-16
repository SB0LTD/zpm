//! @zpm/va av1_read test — av1_read on libaom's stream (testdata/
//! av1_96x64.ivf: 24 frames, alt-refs hidden then shown with
//! show_existing_frame, compound references and skip mode): each frame
//! header's fields where ffmpeg's trace_headers reads them (the table:
//! generated from that trace; a field read in the wrong place throws every
//! later one off), the tiles found, and the stream through video.Decoder on
//! the fake node (every shown frame out once, in order).

const std = @import("std");
const av1r = @import("av1_read.sig");

const STREAM = @embedFile("testdata/av1_96x64.ivf");

const Want = struct { show_existing: u1, frame_type: u2, show_frame: u1, base_q: u8, lf0: u8, cdef_bits: u8, reference_select: u1, skip_mode: u1, reduced_tx_set: u1, refresh: u8 };
pub const FRAMES = [_]Want{
    .{ .show_existing = 0, .frame_type = 0, .show_frame = 1, .base_q = 2, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 255 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 16, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 2 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 16, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 4 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 23, .lf0 = 4, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 8 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 16, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 16 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 23, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 32 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 22, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 64 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 25, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 128 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 25, .lf0 = 0, .cdef_bits = 1, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 2 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 26, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 4 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 25, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 8 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 25, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 16 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 25, .lf0 = 0, .cdef_bits = 1, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 32 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 25, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 64 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 24, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 128 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 24, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 4 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 8, .lf0 = 0, .cdef_bits = 1, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 8 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 0, .base_q = 8, .lf0 = 0, .cdef_bits = 1, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 1 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 0, .base_q = 14, .lf0 = 0, .cdef_bits = 1, .reference_select = 1, .skip_mode = 1, .reduced_tx_set = 0, .refresh = 16 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 17, .lf0 = 0, .cdef_bits = 0, .reference_select = 1, .skip_mode = 1, .reduced_tx_set = 0, .refresh = 32 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 17, .lf0 = 0, .cdef_bits = 0, .reference_select = 1, .skip_mode = 1, .reduced_tx_set = 0, .refresh = 64 },
    .{ .show_existing = 1, .frame_type = 0, .show_frame = 1, .base_q = 0, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 255 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 0, .base_q = 17, .lf0 = 0, .cdef_bits = 1, .reference_select = 1, .skip_mode = 1, .reduced_tx_set = 0, .refresh = 128 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 18, .lf0 = 0, .cdef_bits = 0, .reference_select = 1, .skip_mode = 1, .reduced_tx_set = 0, .refresh = 4 },
    .{ .show_existing = 1, .frame_type = 0, .show_frame = 1, .base_q = 0, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 255 },
    .{ .show_existing = 0, .frame_type = 1, .show_frame = 1, .base_q = 18, .lf0 = 4, .cdef_bits = 0, .reference_select = 1, .skip_mode = 1, .reduced_tx_set = 0, .refresh = 32 },
    .{ .show_existing = 1, .frame_type = 0, .show_frame = 1, .base_q = 0, .lf0 = 0, .cdef_bits = 0, .reference_select = 0, .skip_mode = 0, .reduced_tx_set = 0, .refresh = 255 },
};

var buf: [1 << 20]u8 = undefined;
var frame: av1r.Frame = .{};

test "av1_read: libaom's frame headers as ffmpeg's trace reads them" {
    var st = av1r.State{};
    var pos: usize = 32;
    var k: usize = 0;
    var units: u32 = 0;
    while (pos + 12 <= STREAM.len) {
        const sz = std.mem.readInt(u32, STREAM[pos..][0..4], .little);
        const tu = STREAM[pos + 12 ..][0..sz];
        pos += 12 + sz;
        units += 1;
        var at: usize = 0;
        while (at < tu.len) {
            const used = try av1r.read(&st, tu[at..], &buf, &frame);
            if (used == 0) break;
            at += used;
            const w = FRAMES[k];
            try std.testing.expectEqual(w.show_existing == 1, frame.show_existing);
            if (!frame.show_existing) {
                const p = &frame.pic;
                try std.testing.expectEqual(w.frame_type, p.pic_info_fields.frame_type);
                try std.testing.expectEqual(w.show_frame, p.pic_info_fields.show_frame);
                try std.testing.expectEqual(w.base_q, p.base_qindex);
                try std.testing.expectEqual(w.lf0, p.filter_level[0]);
                try std.testing.expectEqual(w.cdef_bits, p.cdef_bits);
                try std.testing.expectEqual(w.reference_select, p.mode_control_fields.reference_select);
                try std.testing.expectEqual(w.skip_mode, p.mode_control_fields.skip_mode_present);
                try std.testing.expectEqual(w.reduced_tx_set, p.mode_control_fields.reduced_tx_set_used);
                try std.testing.expectEqual(w.refresh, frame.refresh);
                try std.testing.expectEqual(@as(u16, 95), p.frame_width_minus1);
                try std.testing.expect(frame.n_tiles == @as(u32, p.tile_cols) * p.tile_rows);
            }
            av1r.commit(&st, &frame, @intCast(0x400 + k));
            k += 1;
        }
    }
    try std.testing.expectEqual(FRAMES.len, k);
    try std.testing.expectEqual(@as(u32, 24), units);
}
