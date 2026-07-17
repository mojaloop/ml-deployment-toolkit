# Cloudflare DNS setup

[docs](../../index.md) / [adopter](../index.md) / [provider-setup](index.md) / Cloudflare DNS

**Audiences:** adopter (deploy)

Cloudflare DNS is used by both external-dns (to publish HTTPRoute and Service records automatically) and cert-manager (to solve ACME DNS-01 challenges for the wildcard certificates on `*.int.<domain>` and `*.ext.<domain>`).

For background on the DNS strategy, see [Networking](../../architecture/networking.md#dns-strategy).

---

## API token

Create a scoped API token (not the legacy Global API Key):

1. Open [My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens).
2. **Create Token → Custom token**.
3. Permissions:
   - `Zone` → `DNS` → `Edit`
   - `Zone` → `Zone` → `Read`
4. Zone resources: **Include → Specific zone → `example.com`** (the zone the toolkit will manage records in).
5. Optional TTL and IP filters if your policy requires them.
6. Create and copy the token (shown once).

Put it in `config/environments/<env>/.env`:

```bash
CLOUDFLARE_API_TOKEN="..."
```

The Makefile maps this to `TF_VAR_dns_credentials.cloudflare_api_token` automatically.

Verify the token has the right scope:

```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq .
```

---

## Zone

The toolkit expects the records under `dns.domain` (from `config.yaml`) to be manageable in a Cloudflare zone. Unlike Route53/DigitalOcean, Cloudflare only supports **delegated subdomain zones on the Enterprise plan** — on other plans, host the *parent* domain as the zone (e.g. zone `example.com` for `dns.domain: sw1.example.com`). external-dns and cert-manager find the enclosing zone by suffix and manage the subdomain's records inside it; no delegation needed.

The toolkit will not create or delete the zone itself. Create it once via the dashboard, or via the API:

```bash
# Zone creation needs an account-scoped token (Account → Zone → Edit) or the dashboard;
# the DNS-edit token created above is intentionally too narrow for this.

ZONE_NAME="example.com"

# Look up your account ID
ACCOUNT_ID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_ZONE_ADMIN_TOKEN" \
  https://api.cloudflare.com/client/v4/accounts | jq -r '.result[0].id')

# Create the zone and note the assigned nameservers
curl -s -X POST https://api.cloudflare.com/client/v4/zones \
  -H "Authorization: Bearer $CLOUDFLARE_ZONE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$ZONE_NAME\", \"account\": {\"id\": \"$ACCOUNT_ID\"}, \"type\": \"full\"}" \
  | jq '.result.name_servers'
```

Point the domain's registrar (or, for an Enterprise subdomain zone, the parent zone's NS records) at the two returned `*.ns.cloudflare.com` nameservers, then verify:

```bash
dig +short NS "$ZONE_NAME" @1.1.1.1
# → the two assigned cloudflare nameservers
```

### Proxied vs DNS-only

The toolkit creates all records **DNS-only** (grey cloud) — external-dns is not configured with Cloudflare proxying and cert-manager TXT records are never proxied. Leave it that way: the orange-cloud proxy breaks gateway mTLS, non-HTTP ports, and direct connectivity to the LoadBalancer IPs.

---

## What the toolkit writes to the zone

Once deployed, the toolkit creates:

- A wildcard A/AAAA record for `*.int.<domain>` pointing at the Gateway LoadBalancer IPs (external-dns)
- A wildcard A/AAAA record for `*.ext.<domain>` pointing at the same IPs (external-dns)
- TXT records for ACME DNS-01 challenges (cert-manager)
- For Switches: optional per-DFSP records under `<domain>`

You do not need to pre-create these — external-dns reconciles them from Gateway/HTTPRoute resources.

---

## Next

- Fill in the environment config — see [Configuration](../configuration.md)
- Deploy — [CC](../deployment-cc.md) or [SW](../deployment-sw.md)
