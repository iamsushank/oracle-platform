# oracle-platform

Reusable **Oracle Cloud Always Free** deployment platform for Docker apps.

One VM, many projects: **Terraform** provisions the VM, **Ansible** configures Caddy + apps, each **app repo** builds to GHCR and deploys via SSH with `platform-deploy <app-name>`.

Not tied to any single application — register apps in `apps/*.yml`.

## Architecture

```
oracle-platform (this repo)          your-app repos
├── terraform/  → OCI VM             ├── Dockerfile
├── ansible/    → Caddy, /srv        └── .github/workflows/deploy.yml
└── apps/
    ├── webhook-ingestor.yml  ←── manifest per deployed app
    └── my-other-app.yml
```

## Option A — Push-button via GitHub Actions (recommended)

No local tools. After a one-time secret setup, run the **Provision** workflow and everything
(VM, Caddy, Postgres stack, app deploy) happens in CI. State lives in OCI Object Storage so
re-runs are idempotent. IP-only (no DNS).

### One-time setup

1. **OCI API key** — Console → Profile → API Keys → Add API Key → download PEM, note fingerprint.
2. **OCI Customer Secret Key** — Console → Profile → Customer Secret Keys → Generate (for the
   S3-compatible Terraform state backend). Save the access key + secret.
3. **GitHub PAT** (classic) with `repo` + `workflow` scope — lets the platform push deploy
   secrets to app repos.
4. **SSH keypair** for the deploy user: `ssh-keygen -t ed25519 -f deploy_key -N ""`.
5. **Make the GHCR package public** (one click on the package page) so the VM pulls without a login.

### Repo secrets (`iamsushank/oracle-platform`)

| Secret | Value |
|--------|-------|
| `OCI_PRIVATE_KEY` | Contents of the API private key PEM |
| `OCI_TENANCY_OCID` | Tenancy OCID |
| `OCI_USER_OCID` | User OCID |
| `OCI_FINGERPRINT` | API key fingerprint |
| `OCI_COMPARTMENT_OCID` | Compartment OCID (root = tenancy OCID is fine) |
| `OCI_S3_ACCESS_KEY` | Customer Secret Key — access key |
| `OCI_S3_SECRET_KEY` | Customer Secret Key — secret |
| `PLATFORM_SSH_PRIVATE_KEY` | `deploy_key` (private) |
| `PLATFORM_SSH_PUBLIC_KEY` | `deploy_key.pub` |
| `PLATFORM_GH_TOKEN` | The GitHub PAT |
| `GHCR_PULL_TOKEN` | _Optional_ — only if GHCR images are private |

### Repo variables

| Variable | Value |
|----------|-------|
| `OCI_REGION` | e.g. `ap-mumbai-1` |
| `TF_STATE_BUCKET` | _Optional_ — default `oracle-platform-tfstate` |
| `APP_REPOS` | _Optional_ — space-separated `owner/repo` list; default `iamsushank/webhook-ingestor` |

Set quickly with `gh`:

```bash
gh secret set OCI_PRIVATE_KEY < ~/.oci/oci_api_key.pem -R iamsushank/oracle-platform
gh secret set PLATFORM_SSH_PRIVATE_KEY < deploy_key -R iamsushank/oracle-platform
gh secret set PLATFORM_SSH_PUBLIC_KEY  < deploy_key.pub -R iamsushank/oracle-platform
gh secret set OCI_TENANCY_OCID --body "ocid1.tenancy..." -R iamsushank/oracle-platform
# ...repeat for the remaining secrets...
gh variable set OCI_REGION --body "ap-mumbai-1" -R iamsushank/oracle-platform
```

### Run

- **Actions → Provision → Run workflow** (`action: apply`). It provisions the VM, stores
  Terraform state in Object Storage, publishes `ORACLE_HOST` + `ORACLE_SSH_KEY` to the app
  repos, then chains **Configure** (Ansible) automatically.
- App deploys: every push to an app repo builds the image to GHCR and runs
  `platform-deploy <app>` over SSH. The app-repo workflow is dispatched once at the end of
  provisioning too.
- **Teardown:** run **Provision** with `action: destroy`.

> A1 "out of host capacity" is the most common failure. Re-run **Provision** with a different
> `region` input (e.g. `us-phoenix-1`, `uk-london-1`) — no code change needed.

| Workflow | Trigger | Does |
|----------|---------|------|
| `provision.yml` | manual (`apply`/`destroy`) | Terraform + publish secrets + configure + trigger app deploys |
| `configure.yml` | called by provision, push to `apps/**` or `ansible/**`, or manual | Ansible: app stacks + Caddy + deploy |

---

## Option B — Fully scripted from your laptop

### One-time Oracle API key (only manual step Oracle allows)

1. Console → **Profile → API Keys → Add API Key** → download `~/.oci/oci_api_key.pem`
2. Either fill `.env.platform` OR run `oci setup config` then:

```bash
./scripts/print-oci-env.sh >> .env.platform
```

### Bootstrap everything (one command)

```bash
git clone https://github.com/iamsushank/oracle-platform.git
cd oracle-platform
cp .env.platform.example .env.platform
# edit .env.platform with OCI values (or use print-oci-env.sh)

brew install terraform ansible gh   # macOS; or apt install on Linux
./scripts/bootstrap.sh
```

`bootstrap.sh` runs: Terraform → wait for cloud-init → Ansible → GitHub secrets → triggers `webhook-ingestor` deploy.

Open `http://<VM_IP>/` when done.

---

## Quick start (manual steps)

### 1. Prerequisites

- Oracle Cloud account (Always Free)
- Terraform ≥ 1.5, Ansible
- OCI API key → `~/.oci/oci_api_key.pem`
- SSH keys (laptop + GitHub Actions deploy user)

### 2. Provision VM

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill OCIDs + keys
cd ..
./scripts/provision.sh
```

### 3. Register apps

Each app is one file under `apps/`:

```bash
./scripts/add-app.sh my-new-app
# edit apps/my-new-app.yml — image, port, domain, env
```

### Layout modes

| `layout` | Use case |
|----------|----------|
| `single` | One container (SQLite monolith, simple apps) |
| `stack` | Postgres + API + worker (multi-container) |

Example stack manifest (`apps/webhook-ingestor.yml`):

```yaml
name: webhook-ingestor
layout: stack
port: 8080
image: ghcr.io/iamsushank/webhook-ingestor:latest
stack:
  postgres_image: postgres:16-alpine
  postgres_db: webhooks
env:
  LLM_PROVIDER: mock
  SEED_SAMPLES: "false"
```

### 4. Configure VM

```bash
cd ansible
cp inventory.yml.example inventory.yml    # ansible_host = terraform output instance_public_ip
cp group_vars/platform.yml.example group_vars/platform.yml
cd ..
./scripts/configure.sh
```

Open `http://<PUBLIC_IP>/` (when `platform_ip_fallback: true`).

### 5. Wire each app repo for CI/CD

Copy [`templates/app-deploy.workflow.yml`](templates/app-deploy.workflow.yml) to your app as `.github/workflows/deploy.yml`.

Set `APP_NAME` to match the manifest filename (without `.yml`).

GitHub secrets (same for all app repos):

| Secret | Value |
|--------|--------|
| `ORACLE_HOST` | VM public IP |
| `ORACLE_SSH_KEY` | Private key for `deploy` user |

Make GHCR package **public** (or `docker login ghcr.io` on the VM).

---

## Adding a new project

1. **This repo:** `./scripts/add-app.sh <name>` → edit `apps/<name>.yml` → `./scripts/configure.sh`
2. **App repo:** Dockerfile + workflow from `templates/app-deploy.workflow.yml`
3. **DNS (optional):** `A` record → VM IP; set real `domain` in manifest; re-run configure

Each app needs a **unique `port`** on localhost (8080, 8081, …). Caddy routes by domain.

---

## Manual deploy on VM

```bash
platform-deploy webhook-ingestor   # one app
platform-deploy                    # all apps
```

---

## Layout

```
terraform/           OCI VM, VCN, firewall, cloud-init
ansible/             Caddy + docker compose per app
apps/                One YAML manifest per deployed project
scripts/
  bootstrap.sh       laptop end-to-end (tf → ansible → secrets → deploy)
  provision.sh       terraform apply
  configure.sh       ansible-playbook
  wait-for-ssh.sh    poll until SSH is reachable
  add-app.sh         scaffold new app manifest
  trigger-app-deploys.sh  dispatch deploy workflow on app repos
  generate-tfvars.sh / setup-github-secrets.sh / print-oci-env.sh
.github/workflows/
  provision.yml      push-button infra (Terraform + remote state)
  configure.yml      push-button config (Ansible)
templates/
  app-deploy.workflow.yml   copy into app repos
```

---

## Tear down

```bash
cd terraform && terraform destroy
```

---

## Related repos

- [webhook-ingestor](https://github.com/iamsushank/webhook-ingestor) — example app using this platform (`apps/webhook-ingestor.yml`)
