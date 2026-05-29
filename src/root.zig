const replanner = @import("replanner.zig");

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

test {
    @import("std").testing.refAllDecls(@This());
}
