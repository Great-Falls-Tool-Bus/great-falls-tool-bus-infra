# web-convergence stack — production-convergence carrier for the
# greatfallstoolbus.org on-cluster serving surface.
#
# BLOCKED ON THE PUSH-2 STATEFUL-GITOPS MODULE + OPERATOR ENABLE. This
# stack cannot `tofu init` until the module pin in main.tf is swapped to
# the published coordinate. That is fail-closed by construction, not an
# accident — see docs/decisions/0002-production-convergence-conversion.md.
#
# required_providers is intentionally absent here: the Push-2 module
# carries its own provider requirements, and the root provider
# configuration (kubernetes, via the operator-minted namespace-scoped
# kubeconfig) lands with the pin swap, never before it.

terraform {
  required_version = ">= 1.6.0"

  # Configured via -backend-config=../../backend/honey-web-convergence.s3.hcl
  # State coordinates only — no credentials (same convention as the edge
  # and arc-runners stacks; access keys are env-delivered at ceremony).
  backend "s3" {}
}
