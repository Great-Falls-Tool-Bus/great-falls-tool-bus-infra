# web-convergence — pattern instantiation of site.scaffold
# docs/patterns/production-convergence.md + tofu-agent-carrier.md for
# greatfallstoolbus.org, replacing the push-shaped repository_dispatch +
# kubectl CD mechanic (web-stack.yml) with the ONE pull-shaped carrier.
#
# ============================= BLOCKED =============================
# The module below is the Push-2 stateful-gitops multi-tenant module
# (spec: stateful addendum to site.scaffold production-convergence;
# publication mechanism: TIN-2030 Bazel-registry module shape). It is
# NOT published yet. The placeholder source makes `tofu init` fail
# closed on purpose. PIN-SWAP checklist at publication:
#   1. replace `source` (and add the version pin) with the published
#      coordinate;
#   2. reconcile the PROVISIONAL input names below against the real
#      module variables (they document GFTB's requirements, not the
#      module's final API);
#   3. confirm the carrier resource leaf address inside the module and
#      reconcile config/production-convergence.json `carrier_resource`;
#   4. add the root kubernetes provider configuration (operator-minted
#      namespace-scoped kubeconfig, name-only in git);
#   5. operator enable ceremony LAST: flip
#      config/production-convergence-state.json enabled -> true in a
#      reviewed PR (docs/decisions/0002, "Enable ceremony").
# ===================================================================

locals {
  # --- converged surface (grounded against the live serving stack) ---
  # Values verified 2026-08-06 read-only; sources in ADR 0002 section 2.
  site_repository    = "Great-Falls-Tool-Bus/greatfallstoolbus.org" # public; `main` is the converged symbol
  overlay_repository = "Great-Falls-Tool-Bus/great-falls-tool-bus-infra"

  namespace       = "greatfallstoolbus-org-production"
  deployment_name = "greatfallstoolbus-org"
  container_name  = "greatfallstoolbus-org"
  replicas        = 2

  image_repository = "ghcr.io/great-falls-tool-bus/greatfallstoolbus.org"
  # The site publishes NO moving tag: container-ghcr.yml pushes
  # `sha-<commit>` only. The carrier resolves the site's `main` SHA at
  # plan time, derives the tag from this template, and pins the
  # resolved sha256 digest for the apply (tofu-agent-carrier section 2
  # step 3). A moving tag reaching an apply is a defect.
  image_tag_template = "sha-{site_main_sha}"

  # --- health / served evidence -------------------------------------
  # Readiness == liveness == GET /health on :3000
  # (k8s/web/greatfallstoolbus-org-production/deployment.yaml probes;
  # NetworkPolicy admits :3000 only from the cloudflared tunnel and
  # Prometheus). In-cluster gate: readyReplicas == replicas.
  health_path = "/health"
  health_port = 3000

  # Edge served-evidence hostname. CAVEAT (verified live 2026-08-06):
  # the whole public hostname, /health included, sits behind Cloudflare
  # Access SSO (302 -> sulliwood.cloudflareaccess.com), so an
  # unauthenticated probe never reaches the app. The served-sha
  # assertion needs the CF Access service-token credential named below,
  # or a reviewed Access probe-path decision (ADR 0002 blocker B2).
  edge_hostname = "https://greatfallstoolbus.org"

  # --- kill switch ---------------------------------------------------
  workflow_state_document = "config/production-convergence-state.json"

  # --- carrier operational shape (proposed; operator ratifies) -------
  # The interval IS the contract — no converge-now button exists
  # (tofu-agent-carrier section 3). Changing cadence is a schedule
  # commit.
  schedule = "*/15 * * * *"

  # --- credentials, by NAME only (operator-minted at ceremony) -------
  # Never values, never files in git (AGENTS.md hard rule).
  secret_names = {
    overlay_deploy_key    = "web-convergence-overlay-read-deploy-key" # read-only clone of this repo
    state_backend_keypair = "web-convergence-state-backend"           # rustfs access/secret key pair
    edge_probe_token      = "web-convergence-edge-probe"              # CF Access service token (blocker B2)
  }
}

module "web_convergence" {
  # PIN-SWAP-ON-PUSH-2-PUBLICATION: placeholder source; init fails
  # closed until the published module coordinate + version replace it.
  source = "./PIN-SWAP-ON-PUSH-2-PUBLICATION"

  # PROVISIONAL input names — GFTB-side requirements, reconciled at
  # pin swap (step 2 of the checklist above).
  site_repository         = local.site_repository
  overlay_repository      = local.overlay_repository
  namespace               = local.namespace
  deployment_name         = local.deployment_name
  container_name          = local.container_name
  replicas                = local.replicas
  image_repository        = local.image_repository
  image_tag_template      = local.image_tag_template
  health_path             = local.health_path
  health_port             = local.health_port
  edge_hostname           = local.edge_hostname
  workflow_state_document = local.workflow_state_document
  schedule                = local.schedule
  secret_names            = local.secret_names
}
