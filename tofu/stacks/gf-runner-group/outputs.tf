output "runner_group_contract" {
  description = "Non-secret desired GitHub admission; this is not ARC activation evidence."
  value = {
    group_name              = github_actions_runner_group.flywheel.name
    selected_repository_ids = github_actions_runner_group.flywheel.selected_repository_ids
    visibility              = github_actions_runner_group.flywheel.visibility
  }
}
