# AWS Route53 DNS setup

[docs](../../index.md) / [adopter](../index.md) / [provider-setup](index.md) / AWS Route53 DNS

**Audiences:** adopter (deploy)

AWS Route53 is used by both external-dns (to publish HTTPRoute and Service records automatically) and cert-manager (to solve ACME DNS-01 challenges for the wildcard certificates on `*.int.<domain>` and `*.ext.<domain>`).

Route53 is a natural fit when the infrastructure provider is AWS, but works with any infrastructure provider — DNS is an independent dimension.

For background on the DNS strategy, see [Networking](../../architecture/networking.md#dns-strategy).

---

## Variables and CLI profile

All commands below are parameterized — set these once and the rest is copy-paste:

```bash
export AWS_PROFILE="mojaloop"          # named CLI profile (aws configure --profile mojaloop)
DOMAIN="sw1.example.com"               # must match dns.domain in config.yaml
PARENT_DOMAIN="example.com"            # existing parent zone the subdomain is delegated from
DNS_USER="ml-deployment-toolkit-dns"                 # scoped IAM user the toolkit will use
```

With `AWS_PROFILE` exported, every `aws` command uses that profile; alternatively drop the export and append `--profile mojaloop` to each command. The profile is only for running these setup commands — the toolkit itself does not use profiles; it reads the static key from `.env` (see [IAM credentials](#iam-credentials)).

---

## Hosted zone

The toolkit expects a Route53 hosted zone matching `$DOMAIN`. Create it once:

```bash
aws route53 create-hosted-zone \
  --name "$DOMAIN" \
  --caller-reference "ml-deployment-toolkit-$(date +%s)"
```

Capture the zone ID and its four nameservers:

```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$DOMAIN" --max-items 1 \
  --query 'HostedZones[0].Id' --output text)

aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers'
```

### Delegate from the parent zone

If the parent zone is also in Route53, add the NS delegation records via the CLI:

```bash
PARENT_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$PARENT_DOMAIN" --max-items 1 \
  --query 'HostedZones[0].Id' --output text)

aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers' --output json \
| jq --arg domain "$DOMAIN" '{Changes: [{Action: "UPSERT", ResourceRecordSet: {
    Name: $domain, Type: "NS", TTL: 300,
    ResourceRecords: [.[] | {Value: .}]}}]}' > /tmp/delegation.json

aws route53 change-resource-record-sets \
  --hosted-zone-id "$PARENT_ID" \
  --change-batch file:///tmp/delegation.json
```

If the parent zone lives elsewhere (registrar, Cloudflare, DigitalOcean), add the four NS records there using that provider's UI or API instead.

Verify delegation propagated:

```bash
dig +short NS "$DOMAIN" @1.1.1.1
# → the four awsdns nameservers returned above
```

The toolkit will not create or delete the hosted zone itself.

---

## IAM credentials

Create a dedicated IAM user scoped to the hosted zone, with the permissions external-dns and cert-manager need — do not reuse a personal or admin key in `.env`.

### Scoped IAM user, policy, and access key

Uses `$ZONE_ID` from the previous section, so write changes are limited to this zone (the `List*`/`GetChange` actions do not support resource-level scoping):

```bash
cat > /tmp/${DNS_USER}-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/${ZONE_ID#/hostedzone/}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListHostedZonesByName",
        "route53:ListResourceRecordSets",
        "route53:ListTagsForResource",
        "route53:GetChange"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-user --user-name "$DNS_USER"
aws iam put-user-policy --user-name "$DNS_USER" \
  --policy-name "$DNS_USER" \
  --policy-document "file:///tmp/${DNS_USER}-policy.json"
aws iam create-access-key --user-name "$DNS_USER"
```

Save the `AccessKeyId` and `SecretAccessKey` from the last command.

Put them in `config/environments/<env>/.env`:

```bash
# DNS credentials (consumed via TF_VAR_dns_credentials)
AWS_ACCESS_KEY_ID="AKIA..."
AWS_SECRET_ACCESS_KEY="..."
AWS_REGION="us-east-1"          # Route53 is global, but the SDK requires a region
```

If AWS is **also** your infrastructure provider, the same credentials are used by the Terraform `aws` provider for EKS/VPC. If you want separation, use scoped roles via `AWS_PROFILE` — see your AWS deployment docs (planned).

---

## What the toolkit writes to the zone

Once deployed, the toolkit creates:

- A wildcard A/AAAA record for `*.int.<domain>` pointing at the Gateway LoadBalancer (external-dns)
- A wildcard A/AAAA record for `*.ext.<domain>` pointing at the same target (external-dns)
- TXT records for ACME DNS-01 challenges (cert-manager)
- For Switches: optional per-DFSP records under `<domain>`

You do not need to pre-create these — external-dns reconciles them from Gateway/HTTPRoute resources.

---

## Next

- Fill in the environment config — see [Configuration](../configuration.md)
- Deploy — [CC](../deployment-cc.md) or [SW](../deployment-sw.md)
