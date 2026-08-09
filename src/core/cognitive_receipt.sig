//! @zpm/cognitive-receipt — compile-time resource proof for the SB0 reference.
//!
//! This module contains no benchmark claims. It derives exact storage and
//! arithmetic bounds from the same comptime types used by the runtime, so a
//! capacity or dimension change must update (and re-prove) the receipt.

const std = @import("std");
const vector_memory = @import("vector_memory");
const moment_activation = @import("moment_activation");
const agent_runtime = @import("agent_runtime");

pub const vector_capacity: usize = 256;
pub const vector_dimension: usize = 384;
pub const moment_state_dimension: usize = 256;
pub const moment_feature_dimension: usize = 64;
pub const moment_rank: usize = 16;
pub const moment_goal_dimension: usize = 4;
pub const moment_class_count: usize = 8;

pub const VectorIndex = vector_memory.Store(vector_capacity, vector_dimension);
pub const MomentModel = moment_activation.MomentModel(
    moment_state_dimension,
    moment_feature_dimension,
    moment_rank,
    moment_goal_dimension,
    moment_class_count,
);
pub const MomentState = moment_activation.MomentState(
    moment_state_dimension,
    moment_feature_dimension,
    moment_rank,
    moment_goal_dimension,
    moment_class_count,
);

pub const Receipt = struct {
    vector_static_bytes: usize,
    vector_payload_bytes: usize,
    vector_query_multiplications: usize,
    vector_query_additions: usize,
    vector_query_divisions: usize,
    low_rank_context_macs: usize,
    low_rank_total_linear_multiplications: usize,
    dense_total_linear_multiplications: usize,
    low_rank_parameter_bytes: usize,
    dense_parameter_bytes: usize,
    activation_weight_products: usize,
    plan_maximum_nodes: usize,
    plan_maximum_edges: usize,
    capability_maximum_validation_depth: usize,
    root_revocation_writes: usize,
};

pub fn reference() Receipt {
    const query_norm_multiplications = vector_dimension;
    const per_record_multiplications = vector_dimension + 1;
    const query_norm_additions = vector_dimension;
    const per_record_additions = vector_dimension;
    const learned_context = moment_feature_dimension * moment_rank +
        moment_state_dimension * moment_rank;
    const low_rank_total = moment_state_dimension + learned_context +
        moment_state_dimension * moment_goal_dimension;
    const dense_total = moment_state_dimension +
        moment_state_dimension * moment_feature_dimension +
        moment_state_dimension * moment_goal_dimension;
    const low_rank_parameters = moment_class_count *
        (moment_state_dimension + moment_state_dimension * moment_rank +
            moment_feature_dimension * moment_rank) +
        moment_state_dimension * moment_goal_dimension;
    const dense_parameters = moment_class_count *
        (moment_state_dimension + moment_state_dimension * moment_feature_dimension) +
        moment_state_dimension * moment_goal_dimension;
    return .{
        .vector_static_bytes = VectorIndex.staticBytes(),
        .vector_payload_bytes = vector_capacity * vector_dimension * @sizeOf(u16),
        .vector_query_multiplications = query_norm_multiplications + vector_capacity * per_record_multiplications,
        .vector_query_additions = query_norm_additions + vector_capacity * per_record_additions,
        .vector_query_divisions = vector_capacity,
        .low_rank_context_macs = learned_context,
        .low_rank_total_linear_multiplications = low_rank_total,
        .dense_total_linear_multiplications = dense_total,
        .low_rank_parameter_bytes = low_rank_parameters * @sizeOf(f32),
        .dense_parameter_bytes = dense_parameters * @sizeOf(f32),
        .activation_weight_products = 6 * 6,
        .plan_maximum_nodes = 32,
        .plan_maximum_edges = 32 * 31,
        .capability_maximum_validation_depth = 4,
        .root_revocation_writes = 1,
    };
}

test "reference efficiency receipt is exact and internally consistent" {
    const receipt = reference();
    try std.testing.expectEqual(@as(usize, 217_104), receipt.vector_static_bytes);
    try std.testing.expectEqual(@as(usize, 196_608), receipt.vector_payload_bytes);
    try std.testing.expectEqual(@as(usize, 98_944), receipt.vector_query_multiplications);
    try std.testing.expectEqual(@as(usize, 98_688), receipt.vector_query_additions);
    try std.testing.expectEqual(@as(usize, 256), receipt.vector_query_divisions);
    try std.testing.expectEqual(@as(usize, 5_120), receipt.low_rank_context_macs);
    try std.testing.expectEqual(@as(usize, 6_400), receipt.low_rank_total_linear_multiplications);
    try std.testing.expectEqual(@as(usize, 17_664), receipt.dense_total_linear_multiplications);
    try std.testing.expectEqual(@as(usize, 176_128), receipt.low_rank_parameter_bytes);
    try std.testing.expectEqual(@as(usize, 536_576), receipt.dense_parameter_bytes);
    try std.testing.expectEqual(receipt.low_rank_parameter_bytes, MomentModel.staticBytes());
    try std.testing.expect(receipt.vector_static_bytes >= receipt.vector_payload_bytes);
    try std.testing.expect(receipt.vector_static_bytes < 256 * 1024);
    // Cross multiplication proves >67% parameter reduction without floats.
    try std.testing.expect(receipt.low_rank_parameter_bytes * 100 < receipt.dense_parameter_bytes * 33);
    // Cross multiplication proves >63% total linear arithmetic reduction.
    try std.testing.expect(receipt.low_rank_total_linear_multiplications * 100 <
        receipt.dense_total_linear_multiplications * 37);
    try std.testing.expectEqual(@as(usize, 36), receipt.activation_weight_products);
    try std.testing.expectEqual(@as(usize, 1), receipt.root_revocation_writes);
}

test "bounded authority structures remain inline values" {
    const Capabilities = agent_runtime.CapabilityTable(64, 4);
    const Processes = agent_runtime.ProcessTable(8, 128);
    const Plans = agent_runtime.Plan(32);
    try std.testing.expectEqual(@sizeOf(Capabilities), Capabilities.staticBytes());
    try std.testing.expectEqual(@sizeOf(Processes), Processes.staticBytes());
    try std.testing.expectEqual(@sizeOf(Plans), Plans.staticBytes());
}
