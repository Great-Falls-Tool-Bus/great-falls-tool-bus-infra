mock_provider "github" {}

run "owner_admission_is_bounded" {
  command = plan

  assert {
    condition = (
      github_actions_runner_group.flywheel.name == "great-falls-tool-bus-infra"
      && github_actions_runner_group.flywheel.visibility == "selected"
      && !github_actions_runner_group.flywheel.allows_public_repositories
      && !github_actions_runner_group.flywheel.restricted_to_workflows
      && length(github_actions_runner_group.flywheel.selected_repository_ids) == 1
      && contains(github_actions_runner_group.flywheel.selected_repository_ids, 1286829099)
    )
    error_message = "GFTB admission must name only its private overlay in the non-Default owner group."
  }
}
