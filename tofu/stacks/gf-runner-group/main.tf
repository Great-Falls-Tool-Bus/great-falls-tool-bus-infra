locals {
  organization = yamldecode(file("${path.module}/../../../config/organization.yaml"))
  owner        = local.organization.owner
  contract     = local.organization.runner_contract.runner_group
}

provider "github" {
  owner = local.owner.slug
}

resource "github_actions_runner_group" "flywheel" {
  name                       = local.contract.name
  visibility                 = local.contract.visibility
  allows_public_repositories = local.contract.allows_public_repositories
  selected_repository_ids    = toset(local.contract.selected_repository_ids)
  restricted_to_workflows    = local.contract.restricted_to_workflows

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = (
        local.owner.slug == "Great-Falls-Tool-Bus"
        && local.owner.repository == "Great-Falls-Tool-Bus/great-falls-tool-bus-infra"
        && local.owner.repository_id == 1286829099
        && local.owner.repository_visibility == "private"
      )
      error_message = "GFTB runner admission requires the exact private implementation-overlay repository."
    }

    precondition {
      condition = (
        local.contract.name == "great-falls-tool-bus-infra"
        && lower(local.contract.name) != "default"
        && local.contract.visibility == "selected"
        && !local.contract.allows_public_repositories
        && !local.contract.restricted_to_workflows
      )
      error_message = "GFTB capacity must use its selected, private-repository-only non-Default owner group."
    }

    precondition {
      condition = (
        length(local.contract.selected_repository_ids) == 1
        && local.contract.selected_repository_ids[0] == local.owner.repository_id
      )
      error_message = "The GFTB owner group must admit exactly the implementation-overlay repository."
    }
  }
}
