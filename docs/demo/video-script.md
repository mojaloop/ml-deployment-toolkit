# Showcase video script (5 min)

**Audience:** business / architects, secondarily technical.
**Scope:** Proxmox (PVE) infrastructure only — cloud providers mentioned as roadmap.
**Pace:** narration is ~660 words ≈ 4:45 at ~140 wpm, leaving room for pauses on demo screens.

---

## Scene 1 — The pain and the solution (0:00 – 1:00)

**On screen:** slide or the full-deployment topology diagram from [system-overview](../architecture/system-overview.md) (Tooling Cluster + App Environment). Alternatively the repo readme.

**Narration (~130 words):**

> Mojaloop is the open-source real-time payment switch. But running it in production is much more than installing a Helm chart. You need a hardened Kubernetes cluster, secrets management and PKI, mutual TLS for every connected participant, a resilient data layer — MySQL, Kafka, MongoDB — backups, observability, identity and access management. All of it correctly wired together, and kept that way over time.
>
> That's the problem the ML Deployment Toolkit solves. It packages everything below and around the application — infrastructure as code with Terraform, and GitOps manifests reconciled by Flux — into a single distribution. One configuration file, one command, and you get a complete, production-shaped Mojaloop switch. Today it targets on-premise hardware with Proxmox and Talos Linux; more providers are on the roadmap.
>
> Let me show you what a running deployment looks like.

---

## Scene 2 — How it looks (1:00 – 3:00)

Four quick tours, ~30 seconds each. **Pre-open all four tabs/terminals before recording** so you're only switching, never loading.

### 2a — A real transaction from a participant (terminal)

**On screen:** SSH session on the `dfsp-202` VM. Run the CLI transfer (curl to the SDK outbound API) sending from `dfsp-202` to `dfsp-201`. Show the response with `COMMITTED`.

> This is a participant — a bank — connected to the switch over mutual TLS. From its VM, I'll send a real transfer to another participant on the command line… and there it is: party lookup, quote, and transfer, committed end to end in under a second.

### 2b — Finance Portal (positions)

**On screen:** Finance Portal, positions view. Point at the `dfsp-202` and `dfsp-201` positions reflecting the transfer just sent.

> The hub operator sees this immediately in the Finance Portal. Here are the two participants' positions — the transfer we just sent has moved the payer's position up and the payee's down. This is also where the operator manages funds in and out, and settlements.

### 2c — MCM (Connection Manager)

**On screen:** MCM UI, list of onboarded participants; click into one, show certificates / endpoints.

> Onboarding those participants happens in Connection Manager. Each participant's certificates, endpoints and enrollment are managed here — this is what makes the mutual-TLS connectivity you just saw manageable at scale, instead of a pile of hand-maintained certs.

### 2d — Flux UI (how it's all kept running)

**On screen:** Flux UI showing Kustomizations / HelmReleases, everything green.

> And here's the part architects care about: nothing you've seen was installed by hand. Every component — the switch, the data layer, auth, observability — is a Flux-managed release reconciled from a versioned OCI artifact. All green. If someone changes something on the cluster, Flux puts it back. Upgrades are a version bump.

---

## Scene 3 — How to get it (3:00 – 4:30)

### 3a — Get the code and configure (~45s)

**On screen:** terminal + editor. `git clone`, then open `config/environments/<env>/config.yaml`. Scroll slowly through the key blocks while talking. Then flash the `.env` (blur or use dummy values!) and, briefly, a values override file.

> So how do you get one? You clone the toolkit and create a configuration for your environment. It's one YAML file. You pick a sizing profile — sized in transactions per second. You describe your networking: the Proxmox nodes, the virtual IP for the Kubernetes API, and the address range for the gateways. You point it at your backup storage, your observability backend, and optionally an OCI registry cache for air-gapped or bandwidth-constrained sites. Credentials go in a git-ignored env file. And if you need to tune the applications themselves, Helm value overlays are supported — but the defaults are production-shaped out of the box.

### 3b — Deploy (~45s)

**On screen:** run `make plan-apply ENV=<env>`. Cut / time-lapse through the apply, then show `kubectl get nodes` and `kubectl get kustomizations -n flux-system` going Ready, or the Flux UI converging.

> Then: one command. `make plan-apply`. Terraform provisions the virtual machines on Proxmox, boots them with Talos Linux — an immutable, API-managed Kubernetes OS — forms the cluster, and bootstraps Flux. From that point Terraform's job is done: Flux pulls the distribution artifact and converges the whole platform — data layer, auth stack, observability, and Mojaloop itself. About thirty minutes later, you have the switch you saw earlier.

---

## Scene 4 — Close: what's in the box & what's next (4:30 – 5:00)

**On screen:** back to the topology slide, or [docs index](../index.md). End on the repo URL.

**Narration (~70 words):**

> To recap: the ML Deployment Toolkit turns a production Mojaloop deployment from a months-long integration project into configuration plus one command — reproducible, GitOps-managed, and upgradeable. Today it supports on-premise Proxmox with Talos, which makes it a strong fit for deployments that need full control of their infrastructure. Cloud providers are coming next. The docs cover architecture, operations, and participant onboarding — link below. Thanks for watching.

---

## Recording tips

- Send one warm-up transfer before recording so caches are hot and 2a is snappy; then the on-camera transfer creates a fresh position delta for 2b.
- Record the `plan-apply` once ahead of time and time-lapse it — don't do it live.
- In `.env` and `config.yaml`, use dummy credentials or blur; lab domain and IPs are fine to show.
