# GFTB Form Origin Bring-Up

TIN-2420 owns the direct-submit contact/access form. This runbook exists because
the mail and list stack are live, but the browser form is not live yet: the
current public site falls back to `mailto:` until this origin is smoke-proven
and the site deploy lane sets `PUBLIC_GFTB_FORM_ENDPOINT`.

## Runtime Shape

The intended path is:

`visitor -> forms.latoolb.us -> Cloudflare/Blahaj tunnel ->
gftb-form-origin Service -> Anubis :8080 -> form handler :5000 -> postfix 587
STARTTLS/SASL -> keyholders@latoolb.us`.

The static site remains a static spoke. It does not own SMTP credentials,
Cloudflare credentials, Anubis signing material, or a backend.

The Anubis shape follows the upstream operator model: Anubis sits between the
reverse proxy and a target service, Kubernetes deployments put Anubis in front
of the workload, and policy files define `ALLOW` / `DENY` / `CHALLENGE` rules.
Reference docs:
<https://github.com/TecharoHQ/anubis/blob/main/docs/docs/admin/installation.mdx>,
<https://github.com/TecharoHQ/anubis/blob/main/docs/docs/admin/environments/kubernetes.mdx>,
and
<https://github.com/TecharoHQ/anubis/blob/main/docs/docs/admin/policies.mdx>.

## What This Stack Declares

- `form-intake@latoolb.us` MailAccount: non-human submission identity.
- `gftb-form-origin` Deployment: form handler plus Anubis sidecar.
- `gftb-form-origin` Service: exposes Anubis only.
- `gftb-form-origin` NetworkPolicy: tunnel ingress to Anubis and SMTP egress to
  the host-networked postfix endpoint.

The checked-in manifests do not include generated passwords, Anubis private
keys, kubeconfigs, Cloudflare tokens, or DNS credentials.

## Operator Bring-Up Gates

1. Merge the manifest PR.
2. Run `just form-stack-validate`.
3. Apply the `form-intake` MailAccount through the protected mail environment.
4. Project the controller-generated account credential into a Secret named
   `form-intake-smtp` with keys `username` and `password`.
5. Create `gftb-form-anubis-key` with key `ed25519-private-key-hex` (projected
   into the container as Anubis' `ED25519_PRIVATE_KEY_HEX` environment
   variable).
6. Run `just form-stack-server-dry-run` with the namespace kubeconfig.
7. Apply the form stack through the protected mail environment.
8. Route `forms.latoolb.us` through the house tunnel to Service
   `gftb-form-origin` port 80. Do not mutate Cloudflare/DNS from an agent
   session; this is operator-gated.
9. Smoke through the public hostname:
   - `GET /healthz` returns 200 through Anubis policy.
   - A fresh browser is challenged by Anubis before reaching `/contact`.
   - A solved browser can submit a POST to `/contact`.
   - The email reaches `keyholders@latoolb.us` with `Reply-To` set to the
     requester address.
   - Logs do not contain requester names, emails, or message bodies.
10. Only after the POST proof, set `PUBLIC_GFTB_FORM_ENDPOINT` in the public
    site deploy lane.

## POST Challenge Caveat

Anubis is a reverse proxy that challenges browser-like traffic before forwarding
to the upstream service. Its official documentation covers policy actions and
Kubernetes sidecar deployment, but this stack still needs a live proof that the
chosen browser flow does not lose a form body when the first request is a POST.

If a direct cross-site POST from the static site loses the body during the
challenge flow, the fallback is not to bypass Anubis. Route users to
`https://forms.latoolb.us/contact` first, let them pass the challenge
on a GET, then submit the form from the protected origin.

## Validation Commands

```sh
just form-stack-validate
just form-stack-render
GFTB_MAIL_KUBECONFIG=/path/to/namespace.kubeconfig just form-stack-server-dry-run
```

`just form-stack-apply` is intentionally protected and should only run after
the server dry-run and operator review.
