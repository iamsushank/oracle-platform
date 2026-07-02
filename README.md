# oracle-platform

A reusable deployment platform on **Oracle Cloud (OCI) Always Free tier**: one VM that hosts
many Dockerized projects, each with its own Postgres, API service, and background worker,
deployed automatically by GitHub Actions on every push.

**Terraform** creates the infrastructure, **Ansible** configures the VM, and each app repo
gets a small CI workflow that builds an image and deploys it over SSH. Registering a new
project is one YAML file in `apps/`.

```
git push (app repo) ──► GitHub Actions ──► build image ──► GHCR
                                              │
                                              ▼ ssh
                                    Oracle VM: platform-deploy <app>
                                              │
                              docker compose pull && up -d
                                              │
                    Caddy (:80/:443) ──► 127.0.0.1:<port> api ── worker ── postgres
```

---

## Table of contents

1. [Why it works this way (free-tier constraints)](#1-why-it-works-this-way-free-tier-constraints)
2. [Architecture — every component explained](#2-architecture--every-component-explained)
3. [Setup Option A — push-button via GitHub Actions (recommended)](#3-setup-option-a--push-button-via-github-actions-recommended)
4. [Setup Option B — scripted from your laptop](#4-setup-option-b--scripted-from-your-laptop)
5. [Adding a new project](#5-adding-a-new-project)
6. [The app manifest reference](#6-the-app-manifest-reference)
7. [Workflows reference](#7-workflows-reference)
8. [Day-2 operations runbook](#8-day-2-operations-runbook)
9. [Troubleshooting](#9-troubleshooting)
10. [Security notes](#10-security-notes)
11. [FAQ](#11-faq)
12. [Repository layout](#12-repository-layout)

---

## 1. Why it works this way (free-tier constraints)

Oracle's Always Free tier is generous but narrow. Every design choice here maps to a
constraint:

| You'd use on AWS | Oracle free-tier reality | What this platform does instead |
|---|---|---|
| EC2 | ✅ Free: 2× `VM.Standard.E2.1.Micro` (AMD, 1 OCPU/1 GB) **or** `VM.Standard.A1.Flex` (ARM, up to 4 OCPU/24 GB, chronically out of capacity) | One VM, AMD micro by default, with a retry workflow to grab A1 when capacity opens |
| ECS / Fargate | ❌ OCI Container Instances and OKE worker nodes are billed | Docker Compose per app on the VM, Caddy as the shared reverse proxy |
| RDS Postgres | ❌ OCI's managed PostgreSQL is billed (Always Free only includes Oracle Autonomous DB) | `postgres:16-alpine` container per app with a persistent named volume |
| CodeBuild / CodePipeline | ❌ **OCI DevOps** exists (build + deployment pipelines) but build runners are billed per OCPU-hour — not in the Always Free list | GitHub Actions: 2,000 free min/month on private repos, unlimited on public |
| ECR | GHCR is simpler when CI is GitHub Actions | Images pushed to `ghcr.io`, pulled by the VM |
| S3 (for TF state) | ✅ Free: 10 GB Object Storage with an S3-compatible API | Terraform remote state in an OCI bucket via the S3 backend |

Other notable free-tier limits: 200 GB total block storage, 10 TB/month egress,
1 flexible load balancer (unused here — Caddy on the VM is enough).

---

## 2. Architecture — every component explained

### 2.1 Terraform (`terraform/`) — the infrastructure

Creates, in the compartment you point it at:

- **VCN** `10.0.0.0/16` with one public subnet `10.0.1.0/24`, an internet gateway, and a
  route table sending `0.0.0.0/0` through it.
- **Security list** (OCI's firewall at the network layer):
  - TCP 22 from `admin_cidr` (default `0.0.0.0/0`; tighten to your IP — see [Security](#10-security-notes))
  - TCP 80 and 443 from anywhere
  - all egress
- **Compute instance** running the latest Canonical Ubuntu 22.04 image for the chosen shape,
  with a public IP. Shape is `var.instance_shape`:
  - default `VM.Standard.E2.1.Micro` — fixed 1 OCPU/1 GB AMD, always available
  - `VM.Standard.A1.Flex` — set `shape_ocpus`/`shape_memory_gb` (up to 4/24 free); the
    `shape_config` block is applied automatically for `*.Flex` shapes
- **cloud-init** (`terraform/cloud-init.yaml.tftpl`), which on first boot:
  1. creates the `deploy` user (passwordless sudo, your deploy SSH public key)
  2. installs Docker CE + the compose plugin, adds `ubuntu` and `deploy` to the `docker` group
  3. installs Caddy from its official apt repo with a placeholder `:80` responder
  4. creates a **2 GB swapfile** — the 1 GB micro OOMs without it
  5. creates `/srv` (owned by `deploy`) where every app will live
  6. configures UFW: deny incoming except 22/80/443
  7. **fixes an OCI Ubuntu quirk**: the stock image ships a legacy iptables `REJECT` rule
     *above* UFW's chains that only permits SSH, so 80/443 are inserted before it and
     persisted — without this, HTTP is unreachable no matter what UFW says

State backends:

- **CI** uses OCI Object Storage through Terraform's S3-compatible backend
  (`backend.tf.ci` is swapped in by the workflow; auth via a Customer Secret Key).
  This makes provisioning idempotent across runs and machines.
- **Laptop** use keeps local state by default (`backend.tf` + `backend.hcl`).

The VM's public IP is exposed as a Terraform output and becomes the single source of truth,
published to GitHub as the `ORACLE_HOST` variable/secret (see 2.5).

### 2.2 Ansible (`ansible/`) — VM configuration

The playbook `ansible/playbooks/site.yml`:

1. **Loads every `apps/*.yml` manifest** (files starting with `_` are skipped) into
   `platform_apps` — the manifests *are* the desired state; fails if none exist.
2. Runs the `platform` role, which:
   - ensures `deploy` is in the `docker` group and `/srv/<app>` exists per app
   - optionally logs the VM into GHCR (only needed for private images)
   - renders **one Docker Compose file per app** into `/srv/<app>/docker-compose.yml`
     from a template chosen by the manifest's `layout` (see 2.3)
   - runs `docker compose pull` + `up -d --remove-orphans` for each app
   - renders `/etc/caddy/Caddyfile` from all manifests and reloads Caddy
   - installs `platform-deploy` (see 2.4) to `/usr/local/bin`

Ansible is idempotent: re-running it converges the VM to whatever `apps/` describes.
Changing a manifest and re-running Configure is the whole "redeploy config" story.

### 2.3 App layouts — the two compose templates

**`layout: single`** (`docker-compose.yml.j2`) — one container:

```yaml
services:
  app:
    image: <manifest.image>
    ports: ["127.0.0.1:<port>:<container_port>"]   # localhost only!
    environment: <manifest.env>
```

**`layout: stack`** (`docker-compose.stack.yml.j2`) — Postgres + API + worker, all from the
same app image:

```yaml
services:
  db:      postgres:16-alpine, named volume pgdata, healthcheck pg_isready
  api:     <image>, MODE=server, ports ["127.0.0.1:<port>:8080"],
           DATABASE_URL=postgres://postgres:postgres@db:5432/<db>, waits for db healthy
  worker:  <image>, MODE=worker, same DATABASE_URL, waits for db healthy, no ports
```

Conventions the app image must follow for `stack`: listen on `8080`, read `DATABASE_URL`,
and switch between web server and background worker based on the `MODE` env var.
(Adjust the template if your apps use different conventions.)

Key point: **no app port is ever public.** Everything binds to `127.0.0.1`; only Caddy
(80/443) faces the internet. Postgres isn't even bound to the host — it's only reachable
on the app's private compose network.

### 2.4 Caddy + `platform-deploy` — routing and the deploy primitive

`/etc/caddy/Caddyfile` is generated from the manifests:

- while `platform_ip_fallback: true` (default), `http://<PUBLIC_IP>/` proxies to the
  **first** registered app — useful before you own a domain
- every app with a real `domain:` (not `*.example.com`) gets a
  `domain { reverse_proxy 127.0.0.1:<port> }` block — Caddy obtains and renews
  **Let's Encrypt certificates automatically** once DNS points at the VM

`platform-deploy` (installed on the VM) is the entire deploy mechanism:

```bash
platform-deploy <app>   # cd /srv/<app> && docker compose pull && up -d --remove-orphans
platform-deploy         # same, for every app under /srv
# then: docker image prune -f
```

### 2.5 CI/CD — how a push becomes a deployment

Each app repo carries a copy of `templates/app-deploy.workflow.yml`:

1. **build job**: buildx builds the Dockerfile, pushes `ghcr.io/<owner>/<repo>:latest`
   and `:<sha>` (logs into GHCR with the automatic `GITHUB_TOKEN` — no extra secret).
2. **deploy job**: SSHes to the VM as `deploy` (secrets `ORACLE_HOST` + `ORACLE_SSH_KEY`)
   and runs `platform-deploy <APP_NAME>`, which pulls `:latest` and restarts.

The platform side (this repo) has three workflows (details in [§7](#7-workflows-reference)):
**Provision** (Terraform, publishes `ORACLE_HOST`/`ORACLE_SSH_KEY` to every repo listed in
the `APP_REPOS` variable, then chains Configure), **Configure** (Ansible; also auto-runs on
pushes touching `apps/**` or `ansible/**`), and **Retry Provision** (A1 capacity hunting).

### 2.6 SSH keys — who connects as what

One ed25519 keypair (`oracle-platform-deploy`) authorizes the `deploy` user:

| Holder | Purpose |
|---|---|
| Your laptop (`~/.ssh/oracle_platform`) | manual ops, Option B bootstrap |
| Platform repo secret `PLATFORM_SSH_PRIVATE_KEY` | Configure workflow (Ansible over SSH) |
| App repo secret `ORACLE_SSH_KEY` | the deploy job's `platform-deploy` call |

---

## 3. Setup Option A — push-button via GitHub Actions (recommended)

No local Terraform/Ansible needed. One-time secret setup, then everything runs in CI.

### 3.1 Gather credentials (one-time, ~10 minutes)

1. **Oracle account** — sign up for Always Free, note your home region (e.g. `ap-mumbai-1`).
2. **OCI API key** — Console → Profile → **API Keys** → *Add API Key* → download the
   private PEM, note the fingerprint. The config preview also shows your **tenancy OCID**
   and **user OCID** — copy those too.
3. **OCI Customer Secret Key** — Console → Profile → **Customer Secret Keys** → *Generate*.
   This is the S3-style access/secret pair Terraform's state backend uses. Shown **once**.
4. **GitHub PAT** (classic) with `repo` + `workflow` scopes — lets Provision push deploy
   secrets to your app repos and dispatch their workflows.
5. **SSH keypair** for the deploy user:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/oracle_platform -N "" -C "oracle-platform-deploy"
   ```

### 3.2 Set repo secrets and variables

On **this** repo (fork it first):

| Secret | Value |
|---|---|
| `OCI_PRIVATE_KEY` | contents of the API private key PEM |
| `OCI_TENANCY_OCID` | tenancy OCID |
| `OCI_USER_OCID` | user OCID |
| `OCI_FINGERPRINT` | API key fingerprint |
| `OCI_COMPARTMENT_OCID` | compartment OCID (root = tenancy OCID is fine) |
| `OCI_S3_ACCESS_KEY` / `OCI_S3_SECRET_KEY` | Customer Secret Key pair |
| `PLATFORM_SSH_PRIVATE_KEY` / `PLATFORM_SSH_PUBLIC_KEY` | the keypair from step 5 |
| `PLATFORM_GH_TOKEN` | the PAT |
| `GHCR_PULL_TOKEN` | *optional* — only if your GHCR images are private |

| Variable | Value |
|---|---|
| `OCI_REGION` | e.g. `ap-mumbai-1` |
| `APP_REPOS` | space-separated `owner/repo` list to receive deploy secrets |
| `TF_STATE_BUCKET` | *optional*, default `oracle-platform-tfstate` |

Fastest path: fill `.env.platform` (copy from `.env.platform.example`) and run

```bash
./scripts/setup-platform-github-secrets.sh   # pushes all of the above via gh
```

### 3.3 Run it

**Actions → Provision → Run workflow** (`action: apply`). The run:

1. installs the OCI CLI, creates the state bucket if missing
2. `terraform apply` — VCN, VM, cloud-init (state saved to Object Storage)
3. sets `ORACLE_HOST` (repo variable here) and pushes `ORACLE_HOST` + `ORACLE_SSH_KEY`
   secrets to every repo in `APP_REPOS`
4. chains **Configure** — waits for SSH, runs Ansible, brings up all app stacks + Caddy
5. dispatches each app repo's deploy workflow once

When it's green: `http://<ORACLE_HOST>/` serves your first app. Done.

> **A1 capacity note:** if you provision `VM.Standard.A1.Flex` and hit
> *Out of host capacity*, either re-run with a different `region` input, or uncomment the
> `schedule:` block in `retry-provision.yml` and let it retry every 4 h until it lands
> (re-comment afterwards so a timer never touches a healthy VM).

---

## 4. Setup Option B — scripted from your laptop

```bash
git clone https://github.com/iamsushank/oracle-platform.git && cd oracle-platform
brew install terraform ansible gh          # or apt equivalents
cp .env.platform.example .env.platform     # fill OCI values (or: oci setup config && ./scripts/print-oci-env.sh >> .env.platform)
./scripts/bootstrap.sh
```

`bootstrap.sh` chains: generate tfvars → `terraform apply` → wait for SSH →
`ansible-playbook` → push GitHub secrets everywhere → dispatch app deploys.
Same end state as Option A; state stays local unless you configure `backend.hcl`.

Individual pieces, if you prefer manual control:

```bash
./scripts/provision.sh      # terraform only
./scripts/configure.sh      # ansible only
./scripts/setup-platform-github-secrets.sh
./scripts/trigger-app-deploys.sh
```

---

## 5. Adding a new project

**In this repo:**

```bash
./scripts/add-app.sh my-app        # scaffolds apps/my-app.yml from the template
vim apps/my-app.yml                # set image, unique port (8081, 8082…), layout, env
git push                           # push to main touching apps/** auto-runs Configure
```

**In the app repo:**

1. Add a `Dockerfile` (for `stack` layout: serve on 8080, honor `DATABASE_URL` and `MODE`).
2. Copy `templates/app-deploy.workflow.yml` to `.github/workflows/deploy.yml`, set
   `APP_NAME: my-app` (must match the manifest filename).
3. Secrets `ORACLE_HOST` + `ORACLE_SSH_KEY`: added automatically if the repo is in
   `APP_REPOS` when Provision runs; otherwise set them by hand.
4. Make the GHCR package **public** after the first push (package page → settings), or set
   `GHCR_PULL_TOKEN` on the platform repo instead.
5. Push. Watch it deploy.

**Custom domain (optional):** point an `A` record at the VM IP, set `domain:` in the
manifest, push. Caddy picks it up with automatic HTTPS. Set `platform_email` in
`ansible/group_vars/platform.yml` for Let's Encrypt expiry notices, and flip
`platform_ip_fallback: false` once every app has a domain.

Rules of thumb: one manifest = one project; every manifest needs a **unique `port`**;
Caddy is the only public entry point.

---

## 6. The app manifest reference

```yaml
name: my-app                                  # must equal the filename (minus .yml)
layout: stack                                 # single | stack
port: 8081                                    # unique localhost port Caddy proxies to
container_port: 8080                          # single layout only (default 8080)
image: ghcr.io/OWNER/my-app:latest
domain: myapp.example.com                     # optional; ignored while *.example.com
stack:                                        # stack layout only
  postgres_image: postgres:16-alpine          # optional override
  postgres_db: myapp                          # database name
env:                                          # extra env for api AND worker
  NODE_ENV: production
```

---

## 7. Workflows reference

| Workflow | Trigger | What it does |
|---|---|---|
| `provision.yml` | manual (`apply`/`destroy`), or called by retry | OCI CLI + state bucket → Terraform → publish `ORACLE_HOST`/`ORACLE_SSH_KEY` to app repos → chain Configure → dispatch app deploys |
| `configure.yml` | called by Provision; push to `main` touching `apps/**` or `ansible/**`; manual | wait for SSH → Ansible (app stacks + Caddy + `platform-deploy`) |
| `retry-provision.yml` | manual (schedule commented out) | Provision with `capacity_retry: true` and small A1 sizing; capacity errors exit OK so a cron can keep retrying |
| app repos: `deploy.yml` | push to main / manual | build → GHCR (`:latest` + `:sha`) → SSH `platform-deploy <app>` |

Useful inputs: Provision takes `region` (override for capacity hunting), `ocpus`/`memory_gb`
(A1 Flex only — ignored by the default micro shape), `action: destroy` for teardown.
Configure takes `public_ip` (defaults to the `ORACLE_HOST` variable).

---

## 8. Day-2 operations runbook

```bash
ssh -i ~/.ssh/oracle_platform deploy@<ORACLE_HOST>    # shell on the VM

# deploy / restart
platform-deploy my-app                 # pull latest image + restart one app
platform-deploy                        # all apps
cd /srv/my-app && docker compose restart api

# observe
docker ps
docker compose -f /srv/my-app/docker-compose.yml logs -f --tail 100 api
journalctl -u caddy -f
free -h && df -h /

# postgres (stack apps) — psql shell / one-off dump
docker compose -f /srv/my-app/docker-compose.yml exec db psql -U postgres <dbname>
docker compose -f /srv/my-app/docker-compose.yml exec db pg_dump -U postgres <dbname> > backup.sql
```

- **Config redeploy** (manifest/env change): edit `apps/<app>.yml`, push — Configure does the rest.
- **Code redeploy**: push to the app repo — its workflow does the rest.
- **Upgrade to ARM A1** (4 OCPU/24 GB, still free): run **Retry Provision** manually (or
  re-enable its schedule) until Oracle has capacity. ⚠️ Changing shape **replaces the VM**:
  new IP gets republished to app repos automatically, but container data volumes
  (including Postgres) live on the old boot volume — dump databases first.
- **Teardown**: Provision workflow with `action: destroy` (or `cd terraform && terraform destroy`).

---

## 9. Troubleshooting

**Configure/deploy times out "Waiting for SSH" but the VM is fine.**
The classic cause (bit us in production): **GitHub secret storage strips the trailing
newline**, and OpenSSH rejects a private key file without one (`invalid format` →
`Permission denied` → the poll loop times out silently). Workflows here guard against it
by writing keys with `printf '%s\n'` — keep that if you touch them. Debug SSH-from-CI
failures with `ssh -i <key> -v deploy@<ip> true` before suspecting the network:
auth failures and TCP failures look identical through the timeout.

**`Out of host capacity` on A1.Flex.**
Endemic to free-tier ARM. Options: another region (`region` input), smaller size
(1 OCPU/6 GB), the retry schedule, or stay on the AMD micro (default).

**`http://IP/` unreachable though Caddy runs.**
OCI has *two* firewalls: the security list (Terraform handles it) and iptables inside the
image, which ships a legacy `REJECT` above UFW allowing only SSH. cloud-init inserts 80/443
before it and persists. If you rebuild by hand: `sudo iptables -L INPUT -n --line-numbers`.

**Ping fails, everything else works.**
OCI blocks ICMP by default. Probe with `nc -zv <ip> 22` instead.

**Local `terraform output` errors "No valid credential sources".**
State lives in OCI Object Storage; only CI has backend credentials. Get the IP from the
`ORACLE_HOST` repo variable, or export `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` from
your Customer Secret Key and `terraform init -backend-config=backend.hcl`.

**App deploy fails `Error: missing server host`.**
`ORACLE_HOST`/`ORACLE_SSH_KEY` missing in that app repo — repo wasn't in `APP_REPOS`
during Provision. Set them manually or re-run Provision.

**VM slow / OOM on the 1 GB micro.**
Check `free -h` (2 GB swap should exist). Keep images alpine-slim, one stack if possible,
or move to A1. `docker image prune -f` runs on every deploy already.

**GHCR pull fails on the VM.**
Package is private. Make it public, or set `GHCR_PULL_TOKEN` (a PAT with `read:packages`)
on the platform repo and re-run Configure.

---

## 10. Security notes

Current defaults trade some hardening for zero-friction bootstrap. For anything beyond
hobby use:

- **Tighten SSH**: `admin_cidr = "<your-ip>/32"` in `terraform/terraform.tfvars` limits
  port 22 at the network layer. CI (GitHub runners) then can't SSH — run Ansible from your
  laptop (`./scripts/configure.sh`), or keep 22 open and rely on key-only auth (password
  auth is disabled; app ports are never public; Postgres has no host binding at all).
- **Postgres credentials** are `postgres:postgres` inside each stack's private network.
  Unreachable from outside the VM, but parameterize the template if you want unique
  passwords per app.
- The `deploy` user has passwordless sudo (cloud-init needs it once). Drop it after
  bootstrap if you want: `sudo rm /etc/sudoers.d/90-cloud-init-users`, at the cost of
  future Ansible runs needing become passwords.
- **Backups are on you**: free tier gives no automatic DB backups. A nightly
  `pg_dump | gzip` to OCI Object Storage (10 GB free) via cron is the cheapest fix.
- Rotating a leaked deploy key = new keypair → update `PLATFORM_SSH_PRIVATE_KEY`/`_PUBLIC_KEY`
  secrets → re-run Provision (updates the VM's authorized key via metadata + app repo secrets).

---

## 11. FAQ

**Why GitHub Actions and not Oracle's CI (like AWS CodeBuild)?**
Oracle's equivalent is **OCI DevOps** — build pipelines, deployment pipelines, code repos.
Its deployment pipelines are free, but **build runners bill per OCPU-hour and are not part
of Always Free**, so a pure free-tier account can't build with it. GitHub Actions gives
2,000 free minutes/month on private repos (unlimited public), and the code already lives
on GitHub. If you later want builds inside OCI, the swap is contained: replace the build
job in the app workflow; the deploy contract (`platform-deploy` over SSH) stays the same.

**Why not managed Postgres?**
`OCI Database with PostgreSQL` is billed. Always Free includes Oracle Autonomous Database
instead — a different engine entirely. A container with a volume is the free answer.

**Why one VM instead of two free micros?**
Simplicity — one IP, one Caddy, one deploy target. The second free micro is headroom:
duplicate the Terraform instance resource, split apps across VMs, point manifests' repos
at the right `ORACLE_HOST`.

**Can two apps share one Postgres?**
Each stack is isolated on purpose (blast radius, easy teardown). For sharing, extract a
dedicated `postgres` manifest and point other apps' `DATABASE_URL` env at the VM-internal
address — requires publishing the db port on `127.0.0.1` and joining networks; deliberate
extra work.

**What does this cost?**
$0 while you stay inside Always Free limits (this setup does). Oracle may reclaim *idle*
Always Free compute on accounts that never upgraded to Pay-As-You-Go; a busy web app
generally isn't idle. Upgrading to PAYG keeps the free allowances and stops reclamation —
but then nothing blocks accidental billable usage, so set budget alerts.

---

## 12. Repository layout

```
.env.platform.example        all credentials/config for the scripted paths (copy → .env.platform, gitignored)
terraform/
  main.tf                    VCN, subnet, security list, IGW, instance, image lookup
  variables.tf               shape, region, CIDRs, keys — every knob documented inline
  cloud-init.yaml.tftpl      first boot: deploy user, Docker, Caddy, swap, UFW/iptables
  backend.tf / backend.tf.ci local state vs OCI Object Storage state (CI swaps them)
ansible/
  playbooks/site.yml         loads apps/*.yml → runs the platform role
  roles/platform/            tasks + handlers + templates:
    templates/docker-compose.yml.j2        layout: single
    templates/docker-compose.stack.yml.j2  layout: stack (db + api + worker)
    templates/Caddyfile.j2                 IP fallback + per-domain vhosts
    templates/deploy.sh.j2                 → /usr/local/bin/platform-deploy
apps/
  _template.yml              copy me (underscore files are ignored by Ansible)
  webhook-ingestor.yml       live example (stack layout)
templates/
  app-deploy.workflow.yml    copy into each app repo as .github/workflows/deploy.yml
scripts/
  bootstrap.sh               laptop end-to-end (tf → ssh wait → ansible → secrets → deploys)
  provision.sh / configure.sh / wait-for-ssh.sh / add-app.sh
  setup-platform-github-secrets.sh         .env.platform → all GitHub secrets/variables
  trigger-app-deploys.sh / generate-tfvars.sh / print-oci-env.sh
.github/workflows/
  provision.yml              Terraform + secret publishing + chain Configure
  configure.yml              Ansible over SSH
  retry-provision.yml        A1 capacity hunting (schedule commented while VM healthy)
```

---

## Related repos

- [webhook-ingestor](https://github.com/iamsushank/webhook-ingestor) — the live example app
  (`apps/webhook-ingestor.yml`): Go binary that serves API or worker depending on `MODE`.
