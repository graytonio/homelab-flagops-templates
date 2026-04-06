# External DNS Public Deployment Feature Flag - Design

**Goal:** Gate the public external-dns deployment (Cloudflare DNS registration) via a FlagOps environment variable so staging never registers public DNS records.

**Architecture:** The `external-dns` chart deploys `public` and `private` as aliased Bitnami sub-charts. Helm sub-chart aliases respect an `enabled` key — setting it to `false` skips rendering that sub-chart entirely. Adding `enabled: [{ env "external_dns_public_enabled" }]` to the `public:` block in `values.yaml` is sufficient. No app-level changes are needed; the private external-dns and AdGuard deployments are unaffected.

**Environment values:**
- Production Flagsmith: `external_dns_public_enabled = true`
- Staging Flagsmith: `external_dns_public_enabled = false`

## Change

**`apps/external-dns/values.yaml`** — add one line to the `public:` block:

```yaml
public:
  enabled: [{ env "external_dns_public_enabled" }]
  image:
    repository: bitnamilegacy/external-dns
  # ... rest unchanged
```

## Out of Scope

- Per-app `access: public` label changes — not needed since external-dns public won't run
- homeassistant's existing `external_service_public_endpoint_enabled` flag — already handled separately and unrelated to DNS registration
