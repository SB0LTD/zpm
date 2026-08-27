//! @zpm/cognitive-receipt — compile-time resource proof for the SB0 reference.
//!
//! This module contains no benchmark claims. It derives exact storage and
//! arithmetic bounds from the same comptime types used by the runtime, so a
//! capacity or dimension change must update (and re-prove) the receipt.


const vector_memory = @import("vector_memory");
const moment_activation = @import("moment_activation");
const agent_runtime = @import("agent_runtime");
const model_observability = @import("model_observability");
const multimodal_now = @import("multimodal_now");

pub const vector_capacity: usize = 256;
pub const vector_dimension: usize = 384;
pub const moment_state_dimension: usize = 256;
pub const moment_feature_dimension: usize = 64;
pub const moment_rank: usize = 16;
pub const moment_goal_dimension: usize = 4;
pub const moment_class_count: usize = 8;
pub const model_trace_capacity: usize = 512;
pub const now_fusion_dimension: usize = 64;
pub const now_fusion_minimum_prefix: usize = 16;

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
pub const ModelTrace = model_observability.Trace(model_trace_capacity);
pub const NowFusion = multimodal_now.Fusion(now_fusion_dimension, now_fusion_minimum_prefix);

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
    model_trace_event_bytes: usize,
    model_trace_payload_bytes: usize,
    model_trace_static_bytes: usize,
    model_trace_histogram_buckets: usize,
    now_fusion_static_bytes: usize,
    now_fusion_maximum_modalities: usize,
    now_fusion_minimum_arithmetic: usize,
    now_fusion_full_arithmetic: usize,
    now_fusion_maximum_arithmetic: usize,
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
        .model_trace_event_bytes = @sizeOf(model_observability.TraceEvent),
        .model_trace_payload_bytes = model_trace_capacity * @sizeOf(model_observability.TraceEvent),
        .model_trace_static_bytes = ModelTrace.staticBytes(),
        .model_trace_histogram_buckets = model_observability.STAGE_COUNT * model_observability.HISTOGRAM_BUCKETS,
        .now_fusion_static_bytes = NowFusion.staticBytes(),
        .now_fusion_maximum_modalities = multimodal_now.MODALITY_COUNT,
        // For one full-prefix modality, fusion performs two weighted-lane
        // operations, one mean division, two norm operations, one normalized
        // output multiplication per lane, and one prefix-independent inverse.
        .now_fusion_minimum_arithmetic = 6 * now_fusion_minimum_prefix + 1,
        .now_fusion_full_arithmetic = 6 * now_fusion_dimension + 1,
        // With M<=5 modalities, the exact worst-case bound is
        // 2*M*D weighted operations + 4*D normalization operations + 1.
        .now_fusion_maximum_arithmetic =
            (2 * multimodal_now.MODALITY_COUNT + 4) * now_fusion_dimension + 1,
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
    try std.testing.expectEqual(@as(usize, 64), receipt.model_trace_event_bytes);
    try std.testing.expectEqual(@as(usize, 32_768), receipt.model_trace_payload_bytes);
    try std.testing.expectEqual(@as(usize, 47_928), receipt.model_trace_static_bytes);
    try std.testing.expectEqual(@as(usize, 1_728), receipt.model_trace_histogram_buckets);
    try std.testing.expectEqual(@as(usize, 1_472), receipt.now_fusion_static_bytes);
    try std.testing.expectEqual(@as(usize, 5), receipt.now_fusion_maximum_modalities);
    try std.testing.expectEqual(@as(usize, 97), receipt.now_fusion_minimum_arithmetic);
    try std.testing.expectEqual(@as(usize, 385), receipt.now_fusion_full_arithmetic);
    try std.testing.expectEqual(@as(usize, 897), receipt.now_fusion_maximum_arithmetic);
    // Excluding the one prefix-independent reciprocal, reducing 64 lanes to
    // 16 reduces every lane-dependent arithmetic operation by exactly 75%.
    try std.testing.expect((receipt.now_fusion_minimum_arithmetic - 1) * 4 ==
        receipt.now_fusion_full_arithmetic - 1);
}

test "bounded authority structures remain inline values" {
    const Capabilities = agent_runtime.CapabilityTable(64, 4);
    const Processes = agent_runtime.ProcessTable(8, 128);
    const Plans = agent_runtime.Plan(32);
    try std.testing.expectEqual(@sizeOf(Capabilities), Capabilities.staticBytes());
    try std.testing.expectEqual(@sizeOf(Processes), Processes.staticBytes());
    try std.testing.expectEqual(@sizeOf(Plans), Plans.staticBytes());
}
