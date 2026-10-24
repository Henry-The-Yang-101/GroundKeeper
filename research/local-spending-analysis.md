# Local spending analysis: AVA research and GroundKeeper design

2026-10-24. The implementation uses Swift domain code and SQL aggregation inside
GroundKeeperCore. No AVA runtime, Python service, model download, or LLM is needed.
SwiftUI renders the facts and manages merchant corrections. Python remains the
existing classifier service; analytics does not depend on classifier inference.

## Source examined

The older [AntV AVA v3.5 branch](https://github.com/antvis/AVA/tree/v3.5), at
commit `8607a45ac6dadbeb2402d11fb0b1e5e3a6f467e0`, contains the deterministic insight
engine. The newer agent-oriented branch is a different architecture.

- [Pipeline](https://github.com/antvis/AVA/blob/v3.5/packages/ava/src/insight/pipeline/insight.ts)
  infers dimensions/measures, aggregates, enumerates candidates and retains a
  bounded set of ranked insights.
- [Extraction](https://github.com/antvis/AVA/blob/v3.5/packages/ava/src/insight/pipeline/extract.ts)
  enumerates subspaces and dispatches eligible detectors. Its default score
  weights pattern significance 0.8 and impact 0.2. Scores are priorities, not
  interchangeable calibrated probabilities across pattern families.
- [Trend extractor](https://github.com/antvis/AVA/blob/v3.5/packages/ava/src/insight/insights/extractors/trend.ts)
  uses a Mann–Kendall test; regression fitting is separate. GroundKeeper uses
  ordered, equal complete weeks rather than arbitrary row positions.
- [Detector implementations](https://github.com/antvis/AVA/tree/v3.5/packages/ava/src/insight/insights/extractors)
  include majority, low variance, category/time-series outliers, change points,
  correlations and homogeneous groups. AVA's majority is max/sum above 0.6;
  category outliers use IQR by default; time-series outliers compare LOWESS
  residuals; change-point proposals are checked using rank-based tests.
- [Narrative generation](https://github.com/antvis/AVA/blob/v3.5/packages/ava/src/insight/ntv/generate/generateTextSpec.ts)
  interpolates type-specific templates into structured text/entity phrases.
  Deterministic narrative generation does not require a language model.

This is an independent implementation of the architectural ideas and standard
statistics, not a bundled/copy-pasted AVA dependency. AVA is MIT licensed; its
source remains useful for comparison. Avoid treating generic data-discovery
heuristics as financial conclusions: e.g., low variance does not establish a
subscription and a “majority” template must really describe >50% of its denominator.

## Adaptation

1. **SQL facts:** one shared filter applies currency, account, merchant, category,
   tag, date/timezone, lifecycle and current category assignments. Reconciled
   transaction IDs determine purchases. Sum integer minor units before passing
   compact aggregates to Swift. Refunds remain distinct from purchases.
2. **Candidate scopes:** overall plus bounded top merchants/categories. Each
   detector has explicit minimum observations, period and data-quality gates.
   No recursive search across arbitrary combinations or unbounded hypothesis scan.
3. **Detection:** pure statistical functions for tie-corrected Mann–Kendall,
   medians/MAD, earlier-history unusual amounts and fixed-window shifts. Majority
   and merchant comparison detectors use exact aggregates. Weekly MK screening
   uses a Bonferroni-style threshold of 0.01 / candidate series plus an effect-size
   gate; serial dependence still limits formal interpretation.
4. **Ranking:** bounded strength and spending share (0.8/0.2), deterministic keys
   for ties, duplicate amount/count series reduction, capped display count, and
   space retained for established overall/category comparisons. No probability
   or “AI confidence” is presented.
5. **Explanation/evidence:** fixed templates use only computed values. Store
   metrics, algorithm version, actual analysis dates, filter and supporting
   canonical transaction revisions. Recompute after corrections; persist dismissal
   and snooze independently of a growing/moving period.

GroundKeeper deliberately substitutes transparent four-week versus four-week
level shifts for AVA's Bayesian/Pettitt change-point combination. It labels the
window rather than estimating an exact change date. Robust merchant baselines
replace global transaction-amount outliers: normal rent should not be surprising
because coffee is cheap. Flat baselines have an explicit fallback, and no selected
purchase contributes to its own historical baseline.

Not ported: generic correlation mining (count/spend relationships are often
mechanical), LOWESS residual discovery, clustering, seasonality, forecasts,
subscription inference, or AVA's full natural-language specification framework.
These need distinct product requirements and validation. The app currently
implements a bounded, finance-specific version of the discovery pipeline.

## Verification and limits

See [current rules and verification](../docs/spending-reports.md). Synthetic
planted patterns and negative cases test mechanics; they do not measure precision
on real bank histories. Conservative descriptor matching can fragment one business
across names, intentionally requiring confirmation. Identical descriptors from
different businesses can still need per-entry corrections. No statement history
proves account completeness, and the findings do not make causal or predictive
claims. The UI explicitly calls them recorded patterns.
