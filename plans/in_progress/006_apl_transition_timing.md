---
id: 006
title: Review shared ABL transition timing
status: in_progress
created: 2026-11-03
updated: 2026-11-03
---

# Shared ABL transition timing

## Context

After removal of the assumed 10 ms release, the user reports a brief dim flash on both high-to-low and low-to-high APL. This is a physical panel transient, not something synthetic shader output can reproduce or measure. Preserve the identical shared compensation in ReShade and DwmBoost.

## Facts and constraints

- The CSV contains static measurements, not temporal response data.
- The current model assumes an 80 ms rising-load response and immediate falling-load response.
- The symptom is consistent with compensation falling too early and rising too slowly, but identifies no exact time constants.
- Existing CPU panel replay tests prove model consistency, not physical response. Immediate-release equality is a regression for that chosen assumption, not universal hardware truth.
- Do not ask for panel measurements or finer timing judgments. Do not add live-hook tracing, lower peak, add accuracy controls, or split the shared algorithm.
- The user directed proceeding from their feedback rather than blocking on unavailable timing data. Tune explicitly from the observed signs; do not present the chosen values as physical measurements.

## Phase 1: basis for correction

Done when a supported correction is identified, or the missing evidence is recorded without speculative changes.

- [x] Record the approved work separately from display-change plan 003 and finished release plan 005
- [x] Review shared filter, sent/filtered-load relationship and gain solve
- [x] Review existing timing references; no further online timing search, per user instruction
- [x] Establish a supported correction or explicitly record why one cannot be determined

### Review result: no justified replacement policy yet

`PanelFilterStep` advances a load-domain single-pole state toward the candidate boosted frame's sent load. `FilteredLoadPercent` rebuilds the candidate tone curve and evaluates that sent load inside the gain bisection. `SolveBoost` recomputes the state for the chosen gain and writes it with that gain. The inspected shared math does not expose a stale-frame gain or an additional release filter to remove.

The model predicts load at the end of a frame interval, then treats its compensation as the gain appropriate to that frame. Whether the physical panel follows that state, a different filtered quantity, or another within-frame response is not established by the static CSV. An average-over-frame model would itself require knowledge of the physical response; it is not a timing-free fix.

The only existing timing reference inspected is libplacebo's peak-detection smoothing in finished plan 001. It does not establish physical panel ABL timing. The user states that online research will not supply the missing timing; no further online search is planned.

The observations bracket release tuning: 10 ms flashed bright; zero flashed dim. Use their midpoint, 5 ms. Rising load was undercompensated with the 80 ms attack; halve it to 40 ms so compensation rises faster. This is a feedback-based tuning step, not a claim of exact physical response. The user explicitly directed continuing with this available evidence instead of stopping for unavailable data. Physical flash removal remains unverified until observed.

## Phase 2: supported implementation

Done when any justified correction is shared and dependent artifacts/documentation agree.

- [x] Apply feedback-directed tuning: initially 40 ms attack / 5 ms release; now 20 ms attack / 7.5 ms release after both flashes remained dim but probably weaker
- [x] Preserve static calibration, peak and common ReShade/DwmBoost implementation
- [x] Regenerate affected generated files through their build/generator
- [x] Align null test and README where behavior changes

## Phase 3: software verification

Done when affected software checks pass, without claiming they verify physical flash removal.

- [ ] Add focused bidirectional checks if shared timing math changes, including bright-return coverage
- [ ] Build affected MSVC Release targets
- [ ] Run panel fit check, EOTF suite and parity checks for affected behavior — skipped for further constant-only tuning at the user's request; the initial suites were stopped, not passed
- [x] Record software results and physical verification limits separately

### Feedback iteration

The user reports both directions still flash dim at 40 ms attack / 5 ms release, probably less than before. Halve attack again to 20 ms. Raise release to 7.5 ms, bisecting the remaining 5–10 ms bracket. Regenerate and build only; no further verification suites for constant-only tuning. First iteration's panel fit check passed at 0.48% mean error; both Release builds succeeded. Full suites were stopped and no passing result is claimed.
