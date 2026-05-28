# Changelog

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
