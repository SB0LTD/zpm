//! Atomic history backend. The host owns the directory and serializes writers.
const journal = @import("fixed_journal");
pub fn File(comptime path: []const u8) type {
    return struct {
        pub fn load(output: []u8) !?usize {
            return journal.load(path, output);
        }
        pub fn save(bytes: []const u8) !void {
            return journal.save(path, bytes);
        }
    };
}
