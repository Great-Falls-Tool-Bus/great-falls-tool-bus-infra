# GFTB owner runner group

This source describes one desired GitHub runner group:
`great-falls-tool-bus-infra`. It admits only implementation-overlay repository
id `1286829099` and refuses public repositories.

The group is admission only. It does not own an ARC release, namespace,
credential, capacity cap, cache profile, or activation. In particular, it does
not authorize changing the adopted `great-falls-tool-bus-nix` release in the
frozen primary `arc-runners` root.

`just runner-group-test` uses a mock provider and never contacts GitHub.
No plan or apply recipe is exposed by this branch. Live adoption or creation
requires a separately reviewed attended plan after repository visibility and
existing-group census are proved. Source does not grant that authorization.
