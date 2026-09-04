{
  description = "Great-Falls-Tool-Bus implementation overlay for GloriousFlywheel";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # actionlint v1.7.12 can deadlock before starting ShellCheck when a
          # run block exceeds the pressured kernel pipe capacity (upstream
          # rhysd/actionlint#650). Consume the signed upstream fix until a
          # release containing it reaches nixpkgs.
          actionlintFixed = pkgs.actionlint.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              (pkgs.fetchurl {
                url = "https://github.com/rhysd/actionlint/commit/fd33e9f582a01a02885c93ae3775e1190cf63653.patch";
                hash = "sha256-9bbCG6LDOSlhpqwskrffWtMqMKBqWnpLz2Jmnm5BHls=";
              })
            ];
          });
        in
        {
          default = pkgs.mkShell {
            packages = [
              actionlintFixed
              pkgs.coreutils
              pkgs.crane
              pkgs.curl
              pkgs.git
              pkgs.gh
              pkgs.gitleaks
              pkgs.git-cliff
              pkgs.jq
              pkgs.just
              pkgs.kubectl
              pkgs.opentofu
              pkgs.openssl
              pkgs.python3
              pkgs.yq-go
              # Toolchain for the declare-only org-tenancy cache-backed Bazel
              # proof (TIN-2364, just flywheel-cache-proof). Cache-first only.
              pkgs.bazelisk
            ];
          };
        });
    };
}
