# aqe-replanner-zig

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

Adaptive query replanner in Zig 0.16. Composes shipped `thompson-bandit-zig` + shipped `workflow-event-log-zig` into a single substrate that ports Spark AQE L846 + Materialize L987 arrangement-reuse + Catalyst L844 rule-engine semantics.

## Status

**v0.0.1 — 7/7 tests pass on Zig 0.16.** Per-(decision_site, variant) `ArmPosterior`; `decide(rng, site, variants)` samples Thompson posterior + returns the chosen variant id; `recordOutcome` updates the posterior + writes the decision event to a workflow event log so subsequent replays are deterministic.

## What ships

- `DecisionSiteId` / `VariantId` / `PlanVariant`.
- `Replanner` with `init` / `deinit` / `decide(rng, site, variants)` / `recordOutcome(site, variant, succeeded, log, workflow_id, seq, ts, payload)` / `meanFor(site, variant)`.
- `encodeDecisionPayload(site, variant, succeeded)` — 16-byte wire form for the workflow event log.
- `SiteKey` hash via splitmix64-style mixer; per-(site, variant) posterior lookup.
- Winning-variant convergence test: hot arm (40 successes / 5 failures) attracts >65% allocation vs cold arm (5/40) across 200 decisions.

## Build

```sh
zig build test                  # 7 unit tests
```

Depends on `../thompson-bandit-zig` + `../workflow-event-log-zig` (sibling castle repos).

## What ships does NOT do (yet)

- **No context-aware bandit.** v0.0.1 ships per-(site, variant) ArmPosterior; v0.0.2 ships LinUCB-style per-feature posterior so the bandit can use plan-fragment statistics (estimated cardinality, schema fingerprint) as context.
- **No replay-deterministic re-derivation.** The decision is logged; v0.0.2 ships replay-side re-derivation so a workflow replay reads back its prior plan choice from the log instead of re-sampling.
- **No arrangement cache + delta-join planner.** Materialize L987 ships these in v0.0.3.
- **No cost model.** v0.0.3 ships the cost model + late-materialisation rule that fold into Catalyst L844 rule-engine integration.
- **No persistence of posterior state.** Memory-only at v0.0.1. v0.0.2 wires the on-disk layer via shipped `tableformat-zig`.

## Composes with shipped substrate

- **`thompson-bandit-zig`** — ArmPosterior + Beta sampler + capacity floor. Same primitive that drives DynamoDB-class adaptive capacity here drives AQE replanning.
- **`workflow-event-log-zig`** — every decision written as an `activity_completed` (success) or `activity_failed` (failure) event so the plan history is replayable + auditable.
- **`expt-substrate` Wyhash seed-derivation** — used by `thompson-bandit-zig` `rngFromSeed`; same seed family across A/B → bandit → replanner.

## Honest non-claims

- Pre-1.0 substrate.
- The decide call is deterministic only if the RNG is seeded; callers must hold the RNG.
- Posterior state is in memory; restart loses it (v0.0.2 persists).
- The variant list passed to `decide` may be a heterogeneous mix; the substrate does NOT validate that variant ids are stable across calls (the caller's contract).

## Credit

Concepts adapted from Spark AQE Adaptive Query Execution (castle L846) + Materialize arrangement reuse + delta-join planning (castle L987) + Catalyst rule-based optimiser (castle L844). Frontier port by Sean Collins (`sean@sunlitmoon.online`).

## License

AGPL-3.0-or-later. See `LICENSE`.
