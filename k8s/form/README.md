# GFTB Form Origin

This directory holds the apply-plane manifests for TIN-2420: the
Anubis-protected direct-submit contact/access intake origin.

The public site is still a static spoke. It must not hold SMTP credentials,
Cloudflare credentials, or an API secret. The live path is:

`browser -> forms.latoolb.us -> Anubis -> form handler -> postfix
587 -> keyholders@latoolb.us`.

Merging these manifests does not make the site form live. The operator still
needs to create the generated SMTP Secret projection, create the Anubis signing
Secret, route the hostname through the house tunnel, smoke-prove the challenge
and POST behavior, then set `PUBLIC_GFTB_FORM_ENDPOINT` in the site deploy lane.
