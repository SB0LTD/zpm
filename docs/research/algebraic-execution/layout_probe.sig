const std=@import("std");
const sql=@import("sql");
const DB=sql.Database(.{.tables=8,.columns=8,.text_bytes=128,.name_bytes=63,.expr_nodes=8192,.relations=4,.external_storage=true,.external_workspace=true,.external_results=true,.compact_integral_scans=true});
pub fn main() !void {
 std.debug.print("{{\"cell_bytes\":{d},\"version_bytes\":{d},\"row_slot_bytes\":{d},\"read_context_bytes\":{d},\"query_cells_65536_bytes\":{d},\"query_refs_65536\":{d},\"read_backing_65536_bytes\":{d}}}\n",.{@sizeOf(DB.Cell),@sizeOf(DB.StorageVersion),@sizeOf(DB.StorageRowSlot),@sizeOf(DB.ReadContext),try DB.queryWorkspaceBytes(65536),try DB.queryReferenceCount(65536),try DB.ReadContext.backingBytes(65536)});
}
