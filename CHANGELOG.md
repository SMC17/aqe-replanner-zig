# Changelog

## 0.0.5 — 2026-05-28

Adds src/cost_replay.zig with CostAwareReplayReplanner. Walks the
workflow event log, ingests both v0.0.4 (16-byte) and v0.0.5 (24-byte)
decision payloads. The 24-byte payload carries observed_cost as f64
bits in bytes 16..24. loadFromLog builds the site to RecordedEntry
map AND seeds the bandit posteriors from history (success when
observed below target).

pickWithReplay returns the recorded variant if a matching candidate
exists AND its observed cost is within tolerance_ratio of the fresh
cost estimate; else falls through to pickByCostThompson. Tolerance
detects cost drift: if cardinality changed 10x since recording, the
recorded choice is stale and the bandit re-samples.

47 to 52 tests pass on Zig 0.16.

## 0.0.4 — 2026-05-28

Adds src/cost_model.zig with three pieces. estimate(plan, cardinalities,
weights, hit_rate) returns CostEstimate = build_cost * new_arrangements
* (1 - hit_rate) + scan_cost * total_card + shuffle_cost. The
arrangement-cache hit_rate dampens build cost for plans that can reuse
existing arrangements; warm-cache delta-join becomes free at the
build-cost component. pickByCostThompson samples each plan's
ArmPosterior and weights by 1/cost; lower cost wins more often.
recordObservedCost updates the posterior using a target_cost
threshold: below target = success, above target = failure.

Convergence test: with 50 simulated trials of (cheap_cost=200,
expensive_cost=5000) at target=1000, the bandit picks the cheap plan
at >= 85 percent of 200 follow-up draws.

38 to 47 tests pass on Zig 0.16.

## 0.0.3 — 2026-05-28

Adds arrangement.zig + delta_join.zig + rule.zig substrates.

ArrangementCache caches per-(table, sorted key_columns) Arrangement
with ref_count and miss/hit telemetry. Normalises unsorted key column
lists before hashing so callers do not have to. Get-or-create returns
existing on hit; allocates on miss.

delta_join.plan(inputs) picks between hash-join and delta-join: each
plan reports the number of NEW arrangements it must materialise; the
substrate selects the plan with the lower count, ties going to delta-
join (cache-coherent and lower memory).

RuleEngine runs pattern-match transformation rules over a PlanNode
AST until a fixed point is reached or max_iterations trips. Demo rules
ship: dropEmptyFilter, foldDoubleProjection, pushProjectionThrough-
Filter (stub).

20 to 38 tests pass on Zig 0.16.

## 0.0.2 — 2026-05-28

Adds Disjoint LinUCB (Li et al. 2010) for contextual-bandit decisions
where decision-time feature vectors carry information (cardinality
estimate, partition count, join type, etc.). Per-arm A matrix and b
vector evolve via outer-product updates; UCB score is theta dot x plus
alpha times sqrt(x dot A inverse x); Gauss-Jordan with partial pivoting
provides numerical stability. Max context dim caps at 8 for v0.0.2.

Adds ReplayReplanner: walks the workflow event log once, builds a
site_id to variant_id map, returns the recorded variant on replay
without consuming an RNG draw. Falls through to the inner Replanner on
unknown sites. Later log entries overwrite earlier ones for the same
site so workflow code that revisits a decision picks the latest.

Convergence test: LinUCB selects the optimal arm at >=85 percent of
the last 20 of 50 trials when one arm always rewards 1 and the other
always rewards 0 under a stable context.

7 to 20 tests pass on Zig 0.16.

## 0.0.1 — 2026-05-28

Adaptive query replanner composing shipped thompson-bandit-zig + shipped
workflow-event-log-zig. Replanner with per-(decision_site, variant)
ArmPosterior; decide(rng, site, variants) samples Thompson posterior +
returns chosen variant id; recordOutcome updates posterior + writes the
decision event to a workflow event log so subsequent replays are
deterministic. 7/7 tests pass on Zig 0.16. Winning-variant convergence
test: hot arm (40/5) attracts >65% allocation vs cold arm (5/40) across
200 decisions.
