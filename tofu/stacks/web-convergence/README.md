# web-convergence — BLOCKED pattern instantiation (do not init)

Production-convergence carrier stack for the greatfallstoolbus.org
on-cluster serving surface, instantiating the Push-2 stateful-gitops
module (unpublished; TIN-2030 publication mechanism). It replaces the
push-shaped `repository_dispatch` + kubectl CD mechanic with the ONE
pull-shaped tofu-agent carrier of
site.scaffold `docs/patterns/production-convergence.md` +
`tofu-agent-carrier.md`.

Status: **BLOCKED, fail-closed by construction.**

- `main.tf` pins a placeholder module source, so `tofu init` fails until
  the published coordinate is swapped in (checklist at the top of
  `main.tf`).
- The kill switch ships halted:
  `config/production-convergence-state.json` has `enabled: false`, and
  the flip to `true` is an operator ceremony in a reviewed PR.
- State backend coordinates (names only, no credentials):
  `tofu/backend/honey-web-convergence.s3.hcl` — bucket `tofu-state`,
  key `great-falls-tool-bus-infra/web-convergence/terraform.tfstate`,
  endpoint `http://tofu-state-rustfs.nix-cache.svc:9000`.
- Health endpoint (grounded read-only 2026-08-06): `GET /health` on
  `:3000` (deployment readiness/liveness probes); the public hostname —
  `/health` included — is behind Cloudflare Access SSO, which the edge
  served-evidence step must account for (ADR 0002 blocker B2).

Decision record, retirement list for the dispatch machinery, blockers,
and the enable ceremony:
`docs/decisions/0002-production-convergence-conversion.md`.

Nothing in this directory applies anything. The live CD path
(`.github/workflows/web-stack.yml`) remains the deploy mechanism until
the enable ceremony completes.
