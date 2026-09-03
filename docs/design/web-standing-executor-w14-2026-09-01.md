# W14 — standing GF-I09 phase-2 web executor for the GFTB web workload (design for ratification)

- **Status:** Proposed — design only. This PR lands no workflow, no RBAC, no
  secret, and no schedule change. Implementation follows W13 (#159) + its
  attended census + operator ratification of this document (see §7).
- **Date:** 2026-09-01
- **Ticket:** TIN-4255 (parent TIN-2609). Apply receipts continue to land on
  TIN-3952 (decisions/0022:279, 336).
- **Authority:** meta `decisions/0022-gftb-site-main-prod-gfi09-carrier-2026-08-30.md`
  §3 (meta `main` blob `378e9ee7…`). Amendment 3 of the same document is
  **spent** — §0 below is load-bearing and comes first.
- **Promoted shape:** the retired generation-45 parity bridge, infra
  `f3b1cc6e:.github/workflows/web-generation-45-parity.yml` (525 lines,
  deleted at `992f5df9` / #167 after its terminal receipt).
- **Observer template:** infra `main:k8s/web/greatfallstoolbus-org-production/web-apply-rbac.yaml`
  (#148, merge `3db67ab4`).
- **Upstream reality:** GloriousFlywheel `docs/architecture/gf-i09-interface-authority.md`
  and `docs/current-state.md` at `origin/main`, quoted where they constrain
  what this executor may claim (§2.4, §7, §8).

## 0. Authority state: Amendment 3 is spent; section 3 is the only path

Amendment 3(a) authorized the one-use carrier "until 2026-09-07 23:59 ET or
until three terminal receipts have been emitted under it, whichever comes
first" (decisions/0022:318-319). Three Amendment-3 bridges have each run to
terminal receipt on infra `main` and been deleted in the `aef4ccd6` shape:

| Generation | Carrier | Retirement |
| --- | --- | --- |
| 43 | `44c9397b` (#158) | `44f9483c` (#160) |
| 44 | `59754b76` (#162, "second use") | `c10ceb02` (#163) |
| 45 | `f3b1cc6e` (#166, "third and final use") | `992f5df9` (#167) |

Amendment 3(d) allowed exactly one escape from the cap: retirement is waived
only if "by then W14 has promoted it to the standing GF-I09 phase-2 executor
under section 3 with `observerIndependent:true` and the credentialed
served-content oracle, in which case section 3 governs and this amendment is
spent" (decisions/0022:374-379). The three receipts landed **before** W14
promoted anything, so the amendment is spent by cap, and "nothing here may be
re-invoked by inference after expiry" (decisions/0022:383).

Consequences this design stands on:

1. **W14 is the section-3 path, not an Amendment-3 promotion in flight.** No
   further apply may claim Amendment-3 authority.
2. **Nothing replaces the per-generation meta amendment.** decisions/0022 §3
   governs. This spec does not request a fourth amendment and defines no
   local substitute authority (0022:131-138: neither Meta nor a GFTB repo may
   define one).
3. **Generation 46+ therefore cannot reach production until §7's ladder
   completes** — GF-I09 phase 2 arms only "after the owning SSOTs
   independently prove publisher, verifier, controller, exact-plan executor,
   observer/readback, bounded retry/self-heal, freeze, liveness, and receipt
   paths" (0022:140-146). If the operator wants an interim bounded lane
   before the upstream legs exist, that is a fresh Meta decision outside this
   spec (§8).

`.github/workflows/` on infra `main` today contains no `web-generation-*`
file, and `scripts/validate-public-operator-surface.py` fails the public
surface if any retired bridge filename reappears. The standing executor is a
**new, reviewed, permanently named** workflow, not a re-arm of a bridge.

## 1. Delta: what changes when one-use becomes standing

The bridge burned "~1,350 throwaway lines each" per generation (TIN-2609
comment `68f54044`): a 525-line workflow whose operand lived in per-generation
env constants, nine frozen render-input digests recomputed at every pin merge
(`f3b1cc6e` bridge:14-19), untracked placeholder fill, and twin SHA-256 pins
inside `validate-public-operator-surface.py`. Its header prose drifted per
copy (bridge:3-9 and :47-48 still narrated generations 44→43 while the env
block carried 45/44) — only env values and inline assertions were ever
load-bearing.

The standing executor inverts the one design choice that forced all of that:
**the workflow is reviewed once and the operand arrives as data.**

| Property | Bridge (one-use) | Standing executor |
| --- | --- | --- |
| Trigger | push on its own workflow file (bridge:20-24) | push on `main` scoped to the pin path (§2.1) |
| Operand | env constants filled per generation (bridge:35-67) | read at run time from the merged pin at `GITHUB_SHA` (§1.1) |
| Render digest | `TARGET_RENDER_SHA256` derived by a transient PR-only proof step (bridge:42-44) | computed in-run; W13's deterministic render makes it a pure function of tree + pin (§1.2) |
| Frozen input digests | nine `sha256sum --check --strict` rows recomputed per generation (bridge:154-164) | none frozen in the file; every constant becomes a run-time derivation from the checked-out pinned tree |
| Validator twin pins | per-bridge workflow SHA-256 in `validate-public-operator-surface.py` | none; the standing file lives under the ordinary reviewed workflow surface |
| Authority per apply | one Meta amendment per bounded window | decisions/0022 §3 — nothing per-generation |
| Retirement | delete after terminal receipt (`aef4ccd6` shape) | remains in place between applies; §2.4 freeze/kill replaces deletion |
| Marginal cost per generation | ~1,350 lines + amendment | one declare-only pin PR |

What carries over **unchanged**: the saved-plan/no-replan contract (§1.2),
the exact operand table (§1.1), the refusal list (§2.3), the machine receipt
(§5.3), the runner/environment/ruleset identity (§2.2), and the Cloudflare
Access boundary — "No Access/DNS/Tunnel/registrar plan or apply, policy
replacement, audience/bypass change, token operation, or route change is
authorized" (0022:200-203, 407-413) applies to every run of the standing
executor exactly as it did to every bridge run.

### 1.1 The operand source: merge-of-pin is the production decision

decisions/0022:320-322 stated the operand under Amendment 3: "Each apply is
of an exact operand: the newest signed `gftb-site` `main` head with a green
CI run and a green publisher run, pinned by a merged declare-only pin PR in
infra." Spent as authority, carried here as the interface definition (§0's
rule, applied the way §5.2 applies it) — that sentence is the whole
interface. Under 0022 §1 phase-2 semantics — "After activation, merge to the
canonical protected `main` declarations is the production decision for
ordinary generations" (0022:36-38) — **merging the declare-only pin PR is
the production decision**; the executor is subordinate to it and decides
nothing.

The pin is `k8s/web/greatfallstoolbus-org-production/deployment.yaml` on
infra `main`. Post-W13 it declares both operand fields in tracked bytes:

- the digest-pinned production image
  (`ghcr.io/great-falls-tool-bus/gftb-site@sha256:…`), and
- the `app.tinyland.dev/source-sha` annotation (committed by W13; the bridge
  era derived it at apply time).

The executor reads the **forward operand** from that file at `GITHUB_SHA` and
the **reverse operand** from the same path at the merge commit's recorded
base (§6). It then re-asserts, against the public `gftb-site` repository via
the GitHub API, that the pinned source sha is a signed `main` commit with a
green CI run and a green publisher run, recording both run ids in the receipt
(`operand.site.*`, §5.3). "Newest" is owned by pin-PR review; greenness and
signature are re-proven mechanically at apply time.

### 1.2 Saved-plan/no-replan, now a pure function (the W13 dependency)

W13 (#159) proves the render is deterministic: eight independent renders
across two separate fresh clones all emit one digest, because "the render
terminates at `cat` of the kustomize output … no re-serialization touches the
emitted bytes." With the synthesized `default-deny-egress` policy and the
source-sha annotation committed, the rendered bytes are a pure function of
(infra tree, pin).

The standing executor therefore keeps the bridge's contract with less
machinery: render reverse then forward via `just web-release-candidate-proof`
+ `just web-release-plan` (bridge:188-208), save both five-file plans
(`rendered.yaml render-sha256 image source-sha carrier-sha`, chmod 600)
**before any credential exists**, and every later step consumes exactly those
saved bytes — server dry-run, mutation, and observation constants alike. No
step replans. Where the bridge asserted a render equal to a pinned env digest,
the standing executor asserts the two independent recipe paths agree with
each other and that the plan's image/source-sha rows equal the operand read in
§1.1 — the digest itself is derived, not declared.

Two bridge constants generalize the same way, because W13 changes both
(#159 touches `networkpolicy.yaml`, `deployment.yaml`, `web-plan.yml`, and
`web-apply-rbac.yaml`):

- the netpol semantic-canonicalization sha (bridge:338 pinned gen-45's
  `301eecb4…`) becomes "live netpol semantics equal the canonicalized
  semantics of the saved plan's policies, computed in-run";
- the exact policy-name census (bridge:339) becomes "live census equals the
  saved plan's census." Post-W13 that census is smaller — the two legacy
  egress allows are gone from both render and RBAC delete lane.

The replicas invariant stays asserted against the saved plan's
`.spec.replicas` (2 today, per ADR 0010 §5; bridge:56, 293).

## 2. Trigger and authority model

### 2.1 Trigger

```yaml
on:
  push:
    branches: [main]
    paths:
      - k8s/web/greatfallstoolbus-org-production/deployment.yaml
```

Per TIN-4255 scope, the executor is "triggered by merged declare-only pin PRs
(not by its own file)." Edits to the executor's own workflow file are
deliberately outside the path filter: changing the executor is an ordinary
reviewed change and must never be an apply. There is no `workflow_dispatch`
and no schedule; a failed run is retried only as a re-run attempt of the same
run, gated by spent-detection (§5.1). This preserves the property that every
mutation is caused by exactly one merged pin.

### 2.2 Fixed identity (unchanged from the bridge and from 0022 §3.1)

| Fact | Value | Source |
| --- | --- | --- |
| Runner | `tinyland-nix` (tinyland-infra pool, exact group/label, fork refusal — operator ruling TIN-4227 `b8f66e62`) | bridge:73; 0022:176-178 |
| Mutator environment | `web-apply`, secret `WEB_APPLY_KUBECONFIG_B64` | bridge:75, 213 |
| Observer environment | `web-observe` (new, distinct; §3) | this spec |
| Ruleset binding | id 20930684, required check `validate`, strict, signatures, squash-only | bridge:139-144 |
| Concurrency | group `gftb-web-standing-executor`, `cancel-in-progress: false` | 0022:35-36 |
| Permissions | `actions: read`, `contents: read`, `pull-requests: read` | bridge:26-33 |

"There is exactly one mutator at every instant" (0022:35-36). The standing
executor holds that law three ways: the concurrency group serializes runs;
the `web-apply` environment secret is referenced by exactly this one
workflow; and the public-surface validator keeps every retired bridge
filename un-recreatable, so no second carrier can be re-armed from history
beside it.

### 2.3 Carried assertions and the refusal list

Step 1 of the bridge (bridge:84-186) carries over whole, with one
generalization. Before touching anything the executor proves, in order:

1. repo identity, `HEAD == GITHUB_SHA`, clean porcelain, no ambient git
   config, pinned origin URL (bridge:102-115);
2. `main` tip equals `GITHUB_SHA` via API, verified signature, single parent
   equal to the recorded base (bridge:118-125);
3. pin-PR merge binding: `merged == true`, `merge_commit_sha` equals the
   carrier, base is `main` at the recorded base, tree-sha equality between
   carrier and PR head, PR-head signature valid (bridge:126-134);
4. **declare-only changed-set, generalized:** the merge commit's changed-set
   is exactly the pin path of §1.1 — this is where "declare-only" stops being
   a review convention and becomes a run-time refusal (replaces the bridge's
   exact 3-file assertion, bridge:135-137);
5. branch ruleset: required signatures, squash-only, strict required check
   `validate` (bridge:139-144);
6. meta ratification pins (`META_MAIN_SHA` / `META_ADR_PATH` / `META_ADR_BLOB`
   / `META_ADR_SHA256`) asserted byte-for-byte (bridge:57-63, 149-152). These
   four constants are the only pins the standing file keeps, because they
   name its authority; they change only when Meta changes, via ordinary
   review of the executor file — which, per §2.1, never triggers an apply;
7. spent-detection across run attempts and prior successful runs on the same
   head (bridge:166-175);
8. web-flow GPG fingerprint pinning + `git verify-commit` (bridge:179-186);
9. the §1.1 operand re-assertions (signed site head, green CI, green
   publisher).

Any failure refuses fail-closed before credential materialization, and every
refusal emits a receipt (§5.3) — refusals are evidence, not silence.

### 2.4 Freeze semantics, and what refuses while upstream is absent

**Freeze/kill.** The bridge froze by deleting itself. A standing executor
needs equivalent controls without deletion: (a) the `web-apply` environment's
protection rules gate every mutating run; (b) disabling the workflow or
revoking `WEB_APPLY_KUBECONFIG_B64` kills the mutation path immediately
without touching declared state; (c) the concurrency group prevents any
overlapping second run; (d) spent-detection makes re-delivery of an
already-receipted head a refusal, not a second apply. Each freeze exercise is
receipted (§7, path 7).

**The arming guard.** GloriousFlywheel's own authority doc is blunt about
what exists upstream: the publisher is "Unassigned", "every
`ApplicationRelease/v1` request therefore refuses with
`ApplicationReleaseVerifierUnavailable`, by construction, in the shipped
binary", and there are "zero live objects"
(`gf-i09-interface-authority.md:24-28, 64-66, 89-92`). W5 (overlay publisher
reusable) and W6 (independent verifier reusable) are "zero code in any
branch, any repo" and unowned (TIN-2609 `68f54044`). Therefore:

- The executor **must not claim GF-I09 objects that do not exist.** It
  consumes the git pin, never a `PublishedApplicationRelease` or
  `PublishedOverlayBundle`; its receipt carries an explicit `gfI09` honesty
  block recording the absent upstream legs (§5.3), and it never fabricates
  publisher, verifier, or controller evidence.
- It fills **only the subordinate exact-plan executor surface of the §3
  composition** (0022:104-106), plus the observer/readback and receipt legs
  this spec adds. §3.1 assigns no executor: it fixes "the previously
  unassigned publication and installation-digest roles" only (0022:161-162)
  — two publishers, the verifier/installation-digest source, and the
  admission consumer (0022:166-169), each barred from plan/apply, the
  consumer explicitly from "applying the workload directly" (0022:169). The
  executor's infra placement rests on the §3 authority table —
  `great-falls-tool-bus-infra` owns "protected apply, probes/receipts"
  (0022:115) — and 0022:182-185 refuses every local substitute on the
  evidence path.
- The implementation lands with a fail-closed arming constant (the bridge's
  placeholder-guard shape, bridge:97-101): until the operator records §7's
  arming event, every run refuses at step 0 with a receipt, mutating
  nothing. Arming is a reviewed one-line change to the executor file — which
  never triggers an apply (§2.1).

**The local-implementation boundary, named rather than cited around.**
0022:108-110 rules that GFTB repos "may declare their instance, binding,
pins, and workload probes" but "must not locally implement self-heal, retry,
freeze, executor, observer, controller-loop, or generic receipt logic", and
0022:131-138 places the "semantics, APIs, safety bounds, implementations,
conformance tests, and reusable workflow tests" of exactly those properties
in the owning GloriousFlywheel, owner-overlay-controller, ci-templates, and
site.scaffold packages. A standing workflow authored in this repository sits
in real tension with that letter. The bridges ran under explicit Meta
amendments (Meta owns exceptions, 0022:114), and Amendment 3 — which
recorded that "the executor already lives in this repository" and named W14
as the promotion "under section 3" (0022:376-379, 385-390) — is spent and
may not be re-invoked by inference (0022:383). This spec therefore does not
claim the tension away; ratification must rule the placement question
explicitly, one of: **(a)** infra's "protected apply, probes/receipts"
ownership (0022:115) covers this instance, with the upstream packages owning
the conformance doctrine/tests the implementation adopts before arming
(0022:131-138); or **(b)** the executor mechanics land as a versioned
reusable surface in ci-templates/site.scaffold, instantiated from infra the
way §3.1's verifier row is (0022:168), with this document as that surface's
specification. Every other section here is compatible with either answer;
arming (§7) waits for the ruling either way.

RATIFICATION RECORD (operator ruling 2026-09-01, TIN-4255 comment
d3130332): ratified with placement (a), the local instance in this
overlay, under an explicit humility bound. The ruling declines to make a
confident doctrine claim: federation through the overlay and the canonical
SSOT remains the preferred end state, and that preference must not block
implementation. This executor is therefore interim, inherently
supersedable substrate work.
TODO(gf-v4): absorb this surface into GF or GF-infra governance when the
v4 substrates exist — as a bzlmod module or an infra-upstream reusable
surface in the 0022:131-138 shape — and retire this local instance. Until
then the conformance doctrine and tests the implementation adopts before
arming still come from the owning upstream packages.

## 3. Observer split: the second identity

TIN-4255: "a second read-only ServiceAccount in a distinct protected
environment (template on `web-apply-rbac.yaml` from #148), so PINNED/RUNNING
readback is not the executor observing itself; flips `observerIndependent` to
true."

The gen-45 receipt was honest about the deficit: `observerIndependent: false,
credentialClass: "bootstrap web-apply readback"` — the post-mutation snapshot
ran with the same kubeconfig that mutated. #148's RBAC carrier already names
the fix in a load-bearing comment: "the permanent carrier must verify the
exact rendered objects before issuing its one-use credential"
(`web-apply-rbac.yaml:20-23`), and its verb layout is the template.

**The observer identity** is that template minus every mutation verb:

- ServiceAccount `web-observe` in `greatfallstoolbus-org-production`,
  `automountServiceAccountToken: false` (matching `web-apply-rbac.yaml:1-9`);
- a Role granting exactly the read census the bridge preflighted
  (bridge:233-238): `get` on the named deployment and named service, `list`
  on replicasets, pods, endpointslices, and networkpolicies — no `create`,
  no `update`, no `patch`, and (post-W13) no `delete` exists to omit;
- a RoleBinding to that ServiceAccount alone. The manifest lands beside
  `web-apply-rbac.yaml` in the same declare-only k8s tree.

**The credential split** is enforced at the GitHub layer, not just RBAC: a
new protected environment `web-observe` holds `WEB_OBSERVE_KUBECONFIG_B64`
(and the oracle credential, §4). The workflow gains a second job — `observe`,
`needs: apply` — which is the only job bound to that environment. The `apply`
job never reads the observer secret; the `observe` job never reads
`WEB_APPLY_KUBECONFIG_B64`. The observer job independently re-derives
PINNED/RUNNING state (the bridge's snapshot invariants, bridge:274-394,
recomputed from the saved plan per §1.2) and the anonymous-access proof
(bridge:395-406), then writes the receipt's `poststate` and `observations`
blocks. A mutating credential never produces the evidence that judges its own
mutation.

**What `observerIndependent: true` claims, exactly.** Credential and identity
independence: distinct ServiceAccount, distinct RBAC surface with zero
mutation verbs, distinct protected environment, distinct secret, distinct
job. It does **not** claim infrastructure independence — both jobs run on the
same `tinyland-nix` pool, fixed by operator ruling (0022:176-178), and in the
same workflow run. The receipt states the credential class of each side
(`mutatorCredentialClass` / `observations.observer.credentialClass`) so the
claim is auditable rather than atmospheric.

## 4. The credentialed served-content oracle

TIN-4255: "Add the credentialed served-content oracle TIN-2611 requires
(authenticated fetch through Access of the source marker), flipping
`authenticatedServedContent` off `pending_operator_look`."

**Mechanism.** The `observe` job performs one additional probe: an
authenticated GET through the production edge — Cloudflare Access in front of
the tunnel and service — using a **Cloudflare Access service token** (the
`CF-Access-Client-Id` / `CF-Access-Client-Secret` header pair), fetching the
site's source marker and asserting it equals `operand.forward.sourceSha`. The
marker is the build-stamped source sha the parity chain already pins; if the
current `gftb-site` build does not expose it at a stable public-safe path,
the implementation PR adds that emission site-side ahead of arming, derived
from the same source sha the publisher stamps into the image. The anonymous
probe stays as-is (`env -i` curl asserting 302 to the pinned
`sulliwood.cloudflareaccess.com` login location, bridge:398-405): the pair
proves the gate still intercepts anonymous traffic AND the origin behind the
gate serves the pinned generation.

**Custody.** The token pair follows the repo's existing secret plane: a
names-only row in `secrets/README.md`
(`cf-access-service-token-gftb-web-observe`), ciphertext as
`secrets/*.enc.yaml` encrypted per the repo-root `.sops.yaml` to the distinct
GFTB tenant age recipient, and the same value held as protected `web-observe`
environment secrets. It lives in the **observer** environment, never the
mutator's: serving-evidence is observation. This is not a browser LOOK and
uses no operator session.

**The Access boundary, honestly.** At run time the executor performs zero
Access mutations — the probe is a read. But the token pair does not exist
today, and admitting a service token requires an Access change (a Service
Auth policy naming it), which decisions/0022 explicitly does not authorize
this carrier to make: no "policy replacement, audience/bypass change, token
operation, or route change" (0022:200-203). Provisioning is therefore a named
prerequisite in §7: an attended, reviewed, one-time change through the
existing edge lane (the `just edge-zones-plan` / `just edge-zones-apply`
stack, whose token scope already covers Access apps and policies), authorized
by the operator as part of ratifying this spec — not an executor action, and
not smuggled in under 0022. The edge review decides the narrowest admission
shape (a separate Access application scoped to the marker path is the
preferred form, so the token can fetch nothing else).

**What it proves, and what still needs the human LOOK.** The oracle proves
SERVED: the production edge path, gate intact, delivers content
byte-derived from the pinned source sha — machine-checkable in every run, so
`authenticatedServedContent` can flip from `"pending_operator_look"` to a
per-run `"verified"` or `"failed"`. It does **not** prove: visual or semantic
correctness of rendered pages (a build can stamp the right sha and still ship
a broken page); the interactive SSO login path (a service token exercises
Service Auth, not the IdP flow humans use); or anything about pages beyond
the marker's binding. Those remain the operator's LOOK — now optional
per-generation taste-checking rather than a load-bearing evidence gap.

## 5. Bounded retry, self-heal, liveness, and receipt schema v3

### 5.1 Bounded retry and self-heal (the bridge's step 5, standing)

The classification gate carries over verbatim in shape (bridge:417-436): live
state is classified from the live image + source-sha as `target` (already
converged: receipt, no mutation), `rollback` (the previous pin: forward apply
proceeds), or `unrelated_drift` (receipt + exit 2, **no mutation** — the
executor self-heals only between its two known operands; unknown drift is an
operator page, never something a subordinate executor "fixes"). The `spent` +
rollback-state combination refuses as `refused_spent` (bridge:442-446).

The retry bound is structural: at most one forward apply and at most one
reverse apply per run (bridge:448-486); a failed run is retried only as a
re-run attempt, and spent-detection (§2.3.7) refuses any attempt after a
terminal receipt exists for the same head. The receipt records
`retry{forwardAttempts, reverseAttempts, bound}` so the bound is evidence,
not prose.

### 5.2 Liveness

Standing liveness is two-sided. Per-apply: every merged pin produces exactly
one executor run whose receipt carries `run{id, attempt, url}` — a pin merge
with no run is a detectable liveness failure, and §7 path 8 receipts one
deliberate exercise. Between applies: the executor sits idle by design; the
existing scheduled `k8s-stack-drift.yml` lane remains the between-applies
drift observer, and the executor's `unrelated_drift` refusal keeps the two
lanes from ever both mutating. (Amendment 3(d) had conditioned standing
presence on exactly this observer split landing, 0022:379-383 — spent as
authority, kept as design intent.)

### 5.3 Receipt schema v3

Schema id: `gftb-web-standing-executor/v3`, extending
`gftb-web-generation-45-parity/v2` (bridge:407-415). Unchanged blocks:
`run`, `saved`, `spent`, `classification`, `prestate`, `mutation`,
`poststate`, and `authority.ruleset` / `authority.meta`. Changes and
additions, each earning its place:

| Field | Change | Why |
| --- | --- | --- |
| `schema` | `"gftb-web-standing-executor/v3"` | new contract name; the generation number leaves the schema |
| `authority.pin{prNumber, mergeSha, baseSha}` | replaces v2's per-generation env-pinned `reviewedBaseSha`/`pr` narration | the operand is data; the receipt records where it was read from |
| `operand.forward{sourceSha, imageDigest, renderSha256}` / `operand.reverse{…}` | new | replaces the `TARGET_*` / `ROLLBACK_*` env constants; digests are derived in-run (§1.2) |
| `operand.site{ciRunId, publisherRunId}` | new | the §1.1 green-CI/green-publisher re-assertion, receipted |
| `observations.observerIndependent` | `true` | §3; the field the promotion exists to flip |
| `observations.observer{job, environment, credentialClass}` | new (`"web-observe"`, `"read-only observer ServiceAccount"`) | makes the independence claim auditable |
| `mutatorCredentialClass` | renamed from v2 `credentialClass` | the split leaves two credential classes; naming both is the honesty |
| `observations.authenticatedServedContent` | `"verified"` or `"failed"` (off `"pending_operator_look"`) | §4; the second field the promotion exists to flip |
| `observations.servedContent{path, expectedSourceSha, observedSourceSha, httpStatus}` | new | the oracle's evidence, not just its verdict |
| `observations.anonymousAccess` | unchanged | the 302 gate proof stays |
| `retry{forwardAttempts, reverseAttempts, bound}` | new | §5.1 |
| `freeze{spentTerminalBeforeRun, concurrencyGroup, armed}` | new (absorbs v2 `spent.terminalBeforeRun`) | §2.4; refusal receipts carry `armed:false` while disarmed |
| `gfI09{phase2Armed, publisher, verifier, controllerAdmission}` | new honesty block | §2.4: records `"absent"` + the owning work item until W5/W6/controller land; carries their run/digest references after |

Receipts upload as a run artifact (30-day retention, bridge:494-501) and
distill to TIN-3952, as every bridge receipt has. Post-mutation credential
and observation material removal keeps the bridge's step-8 shape
(bridge:510-525) in both jobs.

## 6. Rollback

The reverse operand is **the previous pin from git history**: the same
deployment.yaml fields read at the merge commit's recorded base (§1.1). No
separate rollback declaration exists to drift out of date — the pin PR's
parent is the rollback, by construction. §1.2's dual-candidate freeze proves
the reverse plan renders **before any credential exists**, and both saved
plans server-dry-run **before any mutation** (the bridge's step-4 ordering,
bridge:224-251), so a generation whose rollback cannot be proven never
mutates anything.

On any post-mutation failure from a `rollback` classification the executor
reverses exactly as the bridge did (bridge:469-486): reverse server dry-run,
reverse apply via the same audited recipe under the same one-use confirm
gate, then the full rollback snapshot with the observer credential judging
the result (§3). `mutation.rollbackProof` carries the evidence. A failed
forward with a failed reverse is a terminal red receipt and an operator page;
the executor attempts nothing further (§5.1's bound).

## 7. Arming ladder and the nine proof paths

The ladder, in order, each rung gated on the one before it:

1. **W13 (#159) merges**, honoring its own gate: the attended READ-ONLY
   census confirming both legacy egress policies are absent live
   (`docs/runbooks/oncluster-web-cutover.md`, the #159 gate note) — the
   delete lane and the RBAC `delete` verb are removed ahead of live-absence
   evidence, and this spec's render derivations (§1.2) bind to the post-W13
   tree, not gen-45 constants.
2. **This spec is ratified by the operator** (comment on TIN-4255), which
   also rules the §2.4 placement question (local instance vs upstream
   reusable surface) and authorizes the two attended prerequisites it names:
   the `web-observe` environment + RBAC carrier, and the §4 service-token
   edge change.
3. **Implementation PR(s)** land the standing workflow (disarmed, §2.4), the
   observer RBAC manifest, the environments/secrets, and the site-side
   marker if needed — each through ordinary review; none of them mutates the
   workload.
4. **Upstream legs land and are proven by their owning SSOTs** (W5/W6/W7 —
   not GFTB work, §8).
5. **First standing apply under decisions/0022 §3**, with all nine proof
   paths receipted.

The nine (0022:140-146), each with its receipt source and current state:

| # | Path | Receipt source | State today |
| --- | --- | --- | --- |
| 1 | Publisher | ci-templates reusable publisher run (OIDC subject from `gftb-site` protected `main`, 0022:166); referenced in `operand.site.publisherRunId` + `gfI09.publisher` | absent — GF-I09 publisher "Unassigned"; W5 unowned |
| 2 | Verifier | ci-templates verifier evidence carrier + the 3-way digest admission invariant (0022:168); referenced in `gfI09.verifier` | absent — W6 "zero code anywhere", unowned |
| 3 | Controller | owner-overlay-controller admission with non-nil `ApplicationReleaseVerifier` (0022:169); referenced in `gfI09.controllerAdmission` | absent — refuses by construction; zero live objects |
| 4 | Exact-plan executor | this workflow's `apply` job: `saved.*` digests + `mutation.applyOutcome` proving saved-plan identity through subordinate execution | designed here (§1.2, §2); proven twice in bridge form (runs 33331047942, 33366365932) |
| 5 | Observer/readback | the `observe` job: `poststate` + `observations.observer.*` + `observerIndependent:true` | designed here (§3) |
| 6 | Bounded retry/self-heal | `classification` + `mutation.rollback*` + `retry{…}`; one induced-drift exercise receipted at arming | designed here (§5.1, §6); reverse leg exercised in bridge form |
| 7 | Freeze | `freeze{…}` + one receipted kill exercise (environment revoke or workflow disable) at arming | designed here (§2.4) |
| 8 | Liveness | `run{id,attempt,url}` per pin merge + one receipted pin-to-run exercise; `k8s-stack-drift` lane green between applies | designed here (§5.2) |
| 9 | Receipt | the v3 artifact itself + its distillation to TIN-3952, including refusal receipts | designed here (§5.3); v2 receipts already on TIN-3952 |

Rows 1-3 are the honest gap: this spec cannot close them and does not
pretend to (0022:131-138 forbids a local substitute; §2.4 forbids claiming
them). Rows 4-9 are the GFTB-side legs W14 builds — in whichever placement
shape rung 2 rules (§2.4) — as the standing subordinate the §3 composition
binds to when rows 1-3 exist, with the planner/verifier seam left typed in
the receipt (`gfI09` block) but unarmed.

## 8. Non-goals

- **No overlay publisher.** W5, unowned, ci-templates-shaped (0022:167).
- **No verifier.** W6, unowned; the executor never authors verification
  evidence (0022:168, :182-185 — "publisher-authored verification,
  controller-authored verification, or GFTB-local substitute does not
  satisfy").
- **No controller claims.** Admission belongs to
  `tinyland-inc/owner-overlay-controller` (0022:169); the shipped binary's
  refusal-by-construction stands until its owners change it.
- **No GF-I09 object references** until they exist (§2.4).
- **No Access mutation by the executor, ever**; the one-time token admission
  is an attended edge-lane change under §7 rung 2, outside this workflow.
- **No interim authority request.** This spec does not ask Meta for a fourth
  amendment; if generations must ship before §7 rung 4 completes, that
  decision and its bounds belong to the operator and Meta, not this document.
- **No second reconciler, no schedule, no dispatch** — one trigger, one
  mutator, one receipt per pin.
