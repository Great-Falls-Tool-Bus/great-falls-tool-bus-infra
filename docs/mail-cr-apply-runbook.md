# GFTB Mail CR Apply Runbook

Tracking: TIN-2379.

This runbook applies the tenant-owned `MailDomain` and `MailAccount` custom
resources for `latoolb.us`. It does not mint DNS records, DKIM keys, list
services, or secret values.

## Preconditions

- Blahaj tenant namespace grant applied for `latoolb-us-production`.
- The namespace-scoped kubeconfig has been minted from
  `great-falls-tool-bus-apply-token`.
- The kubeconfig value is stored only in the protected `mail` environment as
  `MAIL_APPLY_KUBECONFIG_B64`, or on the operator machine as a local file passed
  through `GFTB_MAIL_KUBECONFIG`. The CI workflow also accepts
  `GFTB_MAIL_KUBECONFIG_B64` as a compatibility alias.
- Blahaj PR #834 or later is deployed so the honey mail transport can accept
  `latoolb.us`.
- If `MailDomain.spec.dkimSecretRef` is present, it must be the operator-
  materialized substrate key reference only: `dkim-keys` /
  `latoolb.us.mail.key`. The CR declares the reference; it does not carry or
  create key material.

## Local operator flow

```bash
just mail-cr-validate
GFTB_MAIL_KUBECONFIG=/path/to/latoolb-us-production.kubeconfig just mail-cr-server-dry-run
GFTB_MAIL_KUBECONFIG=/path/to/latoolb-us-production.kubeconfig just mail-cr-apply
```

## Post-apply read-only checks

```bash
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production get maildomain,mailaccount
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production describe maildomain latoolb-us
kubectl --kubeconfig "$GFTB_MAIL_KUBECONFIG" -n latoolb-us-production describe mailaccount keyholders
```

The domain may report missing DKIM/SPF/DMARC until the DNS and DKIM operator
steps complete. That is expected; do not paper it over in the manifests.
