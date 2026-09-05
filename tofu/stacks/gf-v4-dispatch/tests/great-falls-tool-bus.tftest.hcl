mock_provider "helm" {}
mock_provider "kubernetes" {}

# Every other input comes from great-falls-tool-bus.tfvars through -var-file,
# so this test proves the committed overlay values, not a fixture copy of them.
variables {
  k8s_config_path = "/tmp/gf-v4-dispatch-kubeconfig"
}

run "gftb_release_is_one_remote_only_dispatch_edge" {
  command = plan

  assert {
    condition = (
      output.dispatch_edge.owner == "great-falls-tool-bus"
      && output.dispatch_edge.capability == "gf-v4-dispatch"
      && output.dispatch_edge.runner_namespace == "arc-runners-great-falls-tool-bus"
      && output.dispatch_edge.runner_scale_set_name == "great-falls-tool-bus-gf-v4-dispatch"
      && output.dispatch_edge.github_config_url == "https://github.com/Great-Falls-Tool-Bus"
      && output.dispatch_edge.runner_group == "great-falls-tool-bus-infra"
      && output.dispatch_edge.github_config_secret_name == "github-app-secret-great-falls-tool-bus-gf-v4-dispatch"
      && output.dispatch_edge.runner_image_digest == "7bf301a6275bbe7d8e7b5d063335c9673ce284073606356ffc0900e560026be7"
      && output.dispatch_edge.action_resolution_config_map_name == "gf-v4-action-resolution-endpoint"
      && output.dispatch_edge.action_resolution_config_map_key == "endpoint"
      && output.dispatch_edge.action_resolution_receipt_path == "/etc/tinyland/gf-action-resolution-endpoint"
      && output.dispatch_edge.remote_action_scheduler == "reapi"
      && !output.dispatch_edge.local_build_or_endpoint_fallback
      && !output.dispatch_edge.consumer_supplies_provider_endpoint
      && !output.dispatch_edge.runner_pod_is_compute_scheduling_unit
      && output.chart_authority.owner_release_mode
      && output.chart_authority.chart_source == "vendored"
      && output.chart_authority.atomic
      && output.chart_authority.cleanup_on_fail
      && !output.standing_mutation_authorized
    )
    error_message = "GFTB release must be one immutable, provider-resolved, remote-only gf-v4-dispatch edge"
  }
}

run "repository_registration_is_rejected" {
  command = plan

  variables {
    github_config_url = "https://github.com/Great-Falls-Tool-Bus/gftb-site"
  }

  expect_failures = [var.github_config_url]
}

run "default_runner_group_is_rejected" {
  command = plan

  variables {
    runner_group = "Default"
  }

  expect_failures = [var.runner_group]
}

run "mutable_runner_image_is_rejected" {
  command = plan

  variables {
    runner_image = "ghcr.io/tinyland-inc/actions-runner-nix:main"
  }

  expect_failures = [var.runner_image]
}

run "zero_dispatch_capacity_is_rejected" {
  command = plan

  variables {
    max_runners = 0
  }

  expect_failures = [var.max_runners]
}
