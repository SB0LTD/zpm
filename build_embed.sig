// Helper: exposes build.sig content as an embedded string for property tests.
pub const content = @embedFile("build.sig");
pub const mesh_history = @embedFile("src/core/mesh_history.sig");
pub const mesh_sync = @embedFile("src/core/mesh_sync.sig");
pub const mesh_file = @embedFile("src/platform/mesh_file.sig");
pub const fixed_journal = @embedFile("src/platform/fixed_journal.sig");
