# Changelog

All notable changes to this project will be documented in this file.
## [Unreleased]

### Bug Fixes

- Arc-fmt-check works in a fresh clone — PATH tofu first, GF-core devshell fallback (#2)
- Right-size runner ephemeral envelope 12Gi/16Gi -> 4Gi/8Gi (TIN-2299) (#6)
- Accept mail apply kubeconfig secret (#11)
- Commit the pages_host cutover value + reconcile Access-scope doctrine and token-name docs (#15)
- Import ID discriminator prefix for pages.dev Access app (#17)
- Rewrite kubeconfig for in-cluster CR dry-run (#23)
- Keep DKIM references substrate-owned (#26)
- SPF authorizes honey egress IP — resolves the flagged divergence with live evidence (#28)

### Documentation

- Correct repo-#1 step per prompt-50 doctrine — operator-only spawn, MVP decision gate (#1)
- Add interim GitHub profile avatar asset
- GFTB MVP decision packet (NEW-1, PROPOSED) (#4)
- Packet final — (h) ATTESTED, (g) REV-2 apex gated behind CF Access (TIN-2360) (#7)
- Reconcile edge env protection to free-community-plan reality (operator decision) (#19)
- Truth sweep — row (c) correction note, core-pin sweep, edge prose reconciliation, backend endpoints shape (wf_0118a02c) (#20)

### Features

- Great-Falls-Tool-Bus implementation overlay — sense-3 onboarding (TIN-2299 L6)
- Edge/DNS apply plane re-homed into this overlay (TIN-2360 row c amended) (#8)
- GFTB zone stack for gated apex
- Declare latoolb tenant CRs
- Variable pages_host for the CF Pages cutover (ADR 0003) (#12)
- Gate www.greatfallstoolbus.org with its own Access app (#13)
- Codify the pages.dev Access gate via import block (#16)
- Scheduled zero-diff drift lane + stop uploading .tfplan binaries (D8, wf_0118a02c) (#21)
- Stage latoolb.us mail DNS gated behind mail_dns_enabled (TIN-2379, D11 open) (#22)
- Wire DKIM secretRef + enable latoolb.us mail DNS (D11 closed: self-hosted) (#25)
- Port substrate-boundary validator (TIN-2423) (#24)

### Miscellaneous

- Refresh GF core pin 7072ce2 -> 2281b57 (preflight next-action #1) (#3)
- Gitignore tofu plan artifacts; remove accidentally-committed flip.plan (#14)
- Drop the one-time pages.dev import block (adopted in run 28673911406) (#18)

