# Changelog

## 0.0.1 — 2026-05-28

Adaptive query replanner composing shipped thompson-bandit-zig + shipped
workflow-event-log-zig. Replanner with per-(decision_site, variant)
ArmPosterior; decide(rng, site, variants) samples Thompson posterior +
returns chosen variant id; recordOutcome updates posterior + writes the
decision event to a workflow event log so subsequent replays are
deterministic. 7/7 tests pass on Zig 0.16. Winning-variant convergence
test: hot arm (40/5) attracts >65% allocation vs cold arm (5/40) across
200 decisions.
