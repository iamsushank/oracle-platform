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

## Quick start (fully scripted)

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
  provision.sh       terraform apply
  configure.sh       ansible-playbook
  add-app.sh         scaffold new app manifest
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
