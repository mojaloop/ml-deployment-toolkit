# DigitalOcean DNS setup

[docs](../../index.md) / [adopter](../index.md) / [provider-setup](index.md) / DigitalOcean DNS

**Audiences:** adopter (deploy)

DigitalOcean DNS is used by both external-dns (to publish HTTPRoute and Service records automatically) and cert-manager (to solve ACME DNS-01 challenges for the wildcard certificates on `*.int.<domain>` and `*.ext.<domain>`).

For background on the DNS strategy, see [Networking](../../architecture/networking.md#dns-strategy).

---

## API token

1. Open [Applications & API → Tokens](https://cloud.digitalocean.com/account/api/tokens).
2. Create a **Personal access token** with **read + write** scope. The full-access scope is the simplest; a custom scope works as long as it includes Domain read/write.
3. Copy the value (shown once).

Put it in `config/environments/<env>/.env`:

```bash
DIGITALOCEAN_TOKEN="dop_v1_..."
```

The Makefile maps this to `TF_VAR_dns_credentials.digitalocean_token` automatically; it also feeds the `digitalocean` Terraform provider when DOKS is the infrastructure provider.

---

## Zone

The toolkit expects a DNS zone matching the `dns.domain` value in `config.yaml` (for example, `sw1.example.com`). The zone can be the parent domain or a delegated subdomain — the latter keeps environments isolated.

### Option A — top-level zone in DigitalOcean

If your domain is registered with DigitalOcean or your registrar's nameservers already point to DigitalOcean, no extra setup is needed beyond making sure the zone exists in the DigitalOcean control panel.

### Option B — delegated subdomain zone

Common for multi-environment setups: keep the parent zone wherever it lives, and delegate a subdomain to DigitalOcean so the toolkit can manage records under it independently.

```bash
# 1. Create the subdomain zone in DigitalOcean
doctl compute domain create sw1.example.com

# 2. Add NS delegation records in the parent zone (example: parent is also on DO)
doctl compute domain records create example.com \
  --record-type NS --record-name sw1 --record-data ns1.digitalocean.com. --record-ttl 300
doctl compute domain records create example.com \
  --record-type NS --record-name sw1 --record-data ns2.digitalocean.com. --record-ttl 300
doctl compute domain records create example.com \
  --record-type NS --record-name sw1 --record-data ns3.digitalocean.com. --record-ttl 300
```

If the parent zone is on a different provider (Cloudflare, Route53, registrar's DNS), add the three NS records there using that provider's UI or API.

Verify delegation propagated:

```bash
dig +short NS sw1.example.com @1.1.1.1
# → ns1.digitalocean.com.
#   ns2.digitalocean.com.
#   ns3.digitalocean.com.
```

---

## What the toolkit writes to the zone

Once deployed, the toolkit creates:

- A wildcard A/AAAA record for `*.int.<domain>` pointing at the Gateway LoadBalancer IPs (created by external-dns)
- A wildcard A/AAAA record for `*.ext.<domain>` pointing at the same IPs (created by external-dns)
- TXT records for ACME DNS-01 challenges (created and removed by cert-manager)
- For Switches: optional per-DFSP records under `<domain>` (created on enrollment)

You do not need to pre-create these — external-dns reconciles them from Gateway/HTTPRoute resources.

---

## Next

- Fill in the environment config — see [Configuration](../configuration.md)
- Deploy — [CC](../deployment-cc.md) or [SW](../deployment-sw.md)
