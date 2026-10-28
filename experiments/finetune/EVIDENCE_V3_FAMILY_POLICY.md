# Evidence-v3 family acceptance policy

Policy version: `evidence-v3-family-1`, adopted before model training or selection.
This governs final research adjudication. It does not accept any current row,
change frozen splits, or establish that the assembler has discovered every
relationship. Final acceptance must bind this document's hash and demonstrate
that its rules were applied across the complete cohort and historical registry.

## Identity and split grouping

Keep the observed operating business or distinctive brand separate from the
group used to prevent leakage. A shared split group does not mean that all
members are the same legal entity. Record relationship type, exact affected
rows, actual research evidence, uncertainty, and current input/label hashes.

| Relationship supported by research | Split treatment |
| --- | --- |
| Same business, verified spelling/domain/location alias | Same group. |
| Outlets of a verified operating brand, including franchises | Same brand group; do not assert common franchisee ownership. |
| Businesses or brands under a verified controlling business parent | Same group, retaining separate operating identities. Follow only evidenced controlling links. |
| Different businesses with a verified common actual operator | Same group; a shared address or directory does not establish the operator. |
| Directly operated department or service | Group with the evidenced operating organization. |
| Shared payment processor, checkout software, landlord, campus, booking channel, or independent marketplace platform | No business-ownership union from that relationship alone. |
| Minority investment, common founder, sponsorship, rewards alliance, or shared asset manager | No controlling-parent union from that fact alone. |

Ownership research must distinguish completed transactions from announcements
and preserve relevant temporal limits. Known business continuity across a rename
or ownership change cannot manufacture an unseen family. Do not assert current
ownership from an obsolete source. Investigate large graph bridges rather than
dropping a supported edge to retain more rows.

## Retain useful uncertainty

Uncertain purchase purpose, missing web results, a withheld query, an unknown
local franchisee, or an unknown marketplace seller is **not by itself a reason
to exclude a transaction**. These are important examples of the uncertainty the
model must handle. Preserve input-supported Other/unknown/review targets.

Use the narrowest supported observable identity for such rows. Where only a
billing channel or ambiguous descriptor is visible, retain an explicitly
unresolved group at that observable scope and preserve its historical ownership;
do not invent an underlying seller or treat the channel as its corporate parent.
Consistent matching observable aliases and identical inputs must not cross
splits. Do not use one global unknown family or assign each repeated unknown
descriptor a fresh family to evade this check.

A specific unresolved relationship that could link a candidate to a different
split requires independent adjudication and, if still unresolved, quarantine of
the affected candidates. Record the concrete competing identities or edge and
its affected IDs. Mere lack of an exhaustive public corporate history does not
justify excluding every unfamiliar merchant.

Report retained unresolved-identity rows and their performance separately from
verified-identity rows. Do not describe unresolved groups as proven unseen
businesses. Report exclusions and coverage against all 6,205 reviewed source IDs;
an easier retained subset must not be presented as complete-corpus accuracy.

## Historical ownership and corrections

Use all current rows and the complete historical registry, including excluded
aliases and prior exposure. Preserve the frozen split of every source row.
Never move a historical validation/test family into training, choose a majority
split for a true bridge, or delete a supported relationship to resolve a clash.
Every genuine component spanning multiple splits is quarantined, including a
validation/test-only clash. Missing historical evidence is not an empty history.

A mistaken identity proposal may be corrected with independent, row-specific
research. Preserve the predecessor label/metadata, exact input and label hashes,
evidence, reviewer, rationale and successor hashes. Distinguish a disproven edge
from an unproven one. Corrections must not depend on category targets, model
predictions, desired split sizes or model performance. Immutable source aliases
and split/exposure history remain intact. If the current representation cannot
express a justified correction without erasing history, quarantine it or add
explicit audited support before acceptance.

## Final gate

After all 6,205 primary labels are complete, independently recheck new or changed
identities and every relationship affected by expanded components. Earlier
research may be reused only after checking its exact current row scope and
bindings. A matching hash proves integrity, not merchant identity.

Materialize every verified grouping constraint in the final family plan and
check its transitive closure against the full historical registry. The current
assembler unions original and proposed family aliases; it does not independently
discover corporate parents or prove that all required edges are present. Missing
constraints require evidence-bound metadata reconciliation or implementation
support before assembly, never an assertion that the existing graph is complete.

Bind the policy hash, research/correction decisions, complete current graph,
registry, retained and quarantined ID lists, source/split counts and final labels
in the acceptance record. Run the existing exact-input target-consistency and
cross-split gates as additional checks. Preserve all reviewed rows in the audit.
Only then freeze the canonical training corpus. None of these checks establishes
human-gold category truth or improvement of the new model.
