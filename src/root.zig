const replanner = @import("replanner.zig");

pub const topology_selector = @import("topology_selector.zig");
pub const Topology = topology_selector.Topology;
pub const TopologyId = topology_selector.TopologyId;
pub const selectCheapestFittingTopology = topology_selector.selectCheapestFitting;
pub const anyTopologyFits = topology_selector.anyFits;
pub const cheapestFittingTopologyCost = topology_selector.cheapestFittingCost;

pub const DecisionSiteId = replanner.DecisionSiteId;
pub const VariantId = replanner.VariantId;
pub const PlanVariant = replanner.PlanVariant;
pub const Replanner = replanner.Replanner;
pub const Error = replanner.Error;
pub const encodeDecisionPayload = replanner.encodeDecisionPayload;

pub const linucb = @import("linucb.zig");
pub const LinUcbArm = linucb.LinUcbArm;
pub const linucbSelectArm = linucb.selectArm;
pub const linucb_max_dim = linucb.max_dim;

pub const replay_replanner = @import("replay_replanner.zig");
pub const ReplayReplanner = replay_replanner.ReplayReplanner;

pub const arrangement = @import("arrangement.zig");
pub const ArrangementCache = arrangement.ArrangementCache;
pub const Arrangement = arrangement.Arrangement;

pub const delta_join = @import("delta_join.zig");
pub const JoinInput = delta_join.JoinInput;
pub const JoinPlan = delta_join.JoinPlan;
pub const PlanKind = delta_join.PlanKind;
pub const planJoin = delta_join.plan;

pub const rule = @import("rule.zig");
pub const RuleEngine = rule.RuleEngine;
pub const Rule = rule.Rule;
pub const PlanNode = rule.PlanNode;

pub const cost_model = @import("cost_model.zig");
pub const CostWeights = cost_model.CostWeights;
pub const CostEstimate = cost_model.CostEstimate;
pub const PlanSignature = cost_model.PlanSignature;
pub const costEstimate = cost_model.estimate;
pub const pickByCostThompson = cost_model.pickByCostThompson;
pub const recordObservedCost = cost_model.recordObservedCost;

pub const cost_replay = @import("cost_replay.zig");
pub const CostAwareReplayReplanner = cost_replay.CostAwareReplayReplanner;
pub const encodeCostDecisionPayload = cost_replay.encodeCostDecisionPayload;
pub const cost_payload_len = cost_replay.cost_payload_len;

pub const cost_gated_rules = @import("cost_gated_rules.zig");
pub const CostGatedRuleEngine = cost_gated_rules.CostGatedRuleEngine;
pub const applyGated = cost_gated_rules.applyGated;
pub const estimateNodeCost = cost_gated_rules.estimateNodeCost;
pub const Verdict = cost_gated_rules.Verdict;

pub const optimizer_rule = @import("optimizer_rule.zig");
pub const OptimizerRule = optimizer_rule.OptimizerRule;
pub const OptimizerEngine = optimizer_rule.OptimizerEngine;

pub const rule_library = @import("rule_library.zig");
pub const RuleLibrary = rule_library.Library;

pub const pattern_match = @import("pattern_match.zig");
pub const PlanPattern = pattern_match.PlanPattern;
pub const PatternRule = pattern_match.PatternRule;
pub const Match = pattern_match.Match;

pub const pattern_recursive = @import("pattern_recursive.zig");
pub const applyRecursive = pattern_recursive.applyRecursive;
pub const applyRecursiveAll = pattern_recursive.applyRecursiveAll;
pub const RecursiveResult = pattern_recursive.RecursiveResult;

pub const pattern_cost_gated = @import("pattern_cost_gated.zig");
pub const applyPatternGated = pattern_cost_gated.applyPatternGated;
pub const applyRecursiveGated = pattern_cost_gated.applyRecursiveGated;
pub const recordPatternOutcome = pattern_cost_gated.recordOutcome;

pub const join_reorder = @import("join_reorder.zig");
pub const Relation = join_reorder.Relation;
pub const JoinOrder = join_reorder.JoinOrder;
pub const pickLowestCostOrder = join_reorder.pickLowestCostOrder;
pub const banditPickOrder = join_reorder.banditPickOrder;
pub const OrderPosteriors = join_reorder.OrderPosteriors;

pub const selinger_dp = @import("selinger_dp.zig");
pub const buildSelingerOrder = selinger_dp.buildSelingerOrder;
pub const SelingerDpResult = selinger_dp.DpResult;

pub const vectorised = @import("vectorised.zig");
pub const Batch = vectorised.Batch;
pub const Column = vectorised.Column;
pub const VectorisedRule = vectorised.VectorisedRule;
pub const applyVectorised = vectorised.applyVectorised;
pub const applyVectorisedGated = vectorised.applyVectorisedGated;

pub const null_mask = @import("null_mask.zig");
pub const NullMask = null_mask.NullMask;
pub const intersectNotNull = null_mask.intersectNotNull;
pub const predicateWithNullAware = null_mask.predicateWithNullAware;
pub const countNonNull = null_mask.countNonNull;

pub const null_bits = @import("null_bits.zig");
pub const isValid = null_bits.isValid;
pub const setValid = null_bits.setValid;
pub const setNull = null_bits.setNull;
pub const countValid = null_bits.countValid;
pub const intersectInPlace = null_bits.intersectInPlace;
pub const validityRequiredBytes = null_bits.requiredBytes;
pub const fromBooleans = null_bits.fromBooleans;

pub const vectorised_validity = @import("vectorised_validity.zig");
pub const ValidityBatch = vectorised_validity.ValidityBatch;

pub const string_view = @import("string_view.zig");
pub const StringView = string_view.StringView;
pub const buildInlineStringView = string_view.buildInline;
pub const buildExternalStringView = string_view.buildExternal;
pub const stringPrefixEquals = string_view.prefixEquals;
pub const stringEqualsInline = string_view.equalsInline;

pub const dict_column = @import("dict_column.zig");
pub const DictColumnI64 = dict_column.DictColumnI64;

pub const dict_column_sv = @import("dict_column_sv.zig");
pub const DictColumnStringView = dict_column_sv.DictColumnStringView;

pub const rle_column = @import("rle_column.zig");
pub const RleColumnI64 = rle_column.RleColumnI64;
pub const RleRun = rle_column.Run;

pub const dremel_tree = @import("dremel_tree.zig");
pub const PartialAgg = dremel_tree.PartialAgg;
pub const leafAggregate = dremel_tree.leafAggregate;
pub const dremelMix = dremel_tree.mix;
pub const dremelRoot = dremel_tree.root;

pub const encoding_ladder = @import("encoding_ladder.zig");
pub const Encoding = encoding_ladder.Encoding;
pub const EncodingStats = encoding_ladder.ColumnStats;
pub const pickEncoding = encoding_ladder.pickEncoding;
pub const estimateEncodingBytes = encoding_ladder.estimateBytes;

test {
    @import("std").testing.refAllDecls(@This());
}
