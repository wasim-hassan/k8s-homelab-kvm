# Runbook 09 — Phase 8: CI/CD + image automation

**Goal:** Close the delivery loop — a git tag triggers CI to build and push the `ratlab-demo` image to GHCR, and **Flux image automation** writes the new tag back to git so the cluster deploys it with no manual edit. Add supply-chain artifacts (SBOM, provenance, trivy SARIF) per build. See [ADR-0009](../adr/0009-ci-cd-image-automation.md).

**Topology:** 2-node k3s (`k8s-cp-01` 192.168.123.11, `k8s-worker-01` 192.168.123.12), Devpod workspace, GitOps (Flux **Operator** + `FluxInstance`, now including the image controllers). CI: GitHub Actions → GHCR.

**Preconditions:** Phases 0–7b done; cluster healthy; Flux Healthy; repo pushed to `wasim-hassan/k8s-homelab-kvm`. A GitHub account with admin on the repo (for the one-time deploy key + package visibility). `sops`/age key available in the workspace.

## 01. The app we build — `ratlab-demo`
- Source: [`images/ratlab-demo/`](../../images/ratlab-demo) — `main.go`, `go.mod`, `Containerfile`.
- Endpoints: `/` (version + hostname), `/version` (JSON), `/healthz`, `/readyz`. Env: `PORT` (default `8080`).
- `Containerfile`: `golang:1.23-alpine` build → `scratch`, static binary, `USER 65532:65532`, `EXPOSE 8080`. Single `linux/amd64` platform.
- Version is injected at build: `-ldflags "-X main.version=<tag>"` via the build `ARG VERSION`.

## 02. CI workflow — GitHub Actions → GHCR
- File: [`.github/workflows/ci.yaml`](../../.github/workflows/ci.yaml). Triggers: push to `main` (paths `images/ratlab-demo/**`), `v*` tags, PRs, manual dispatch.
- Permissions: `contents: read`, `packages: write`, `id-token: write`, `attestations: write`, `security-events: write`.
- Steps: `actions/checkout@v4` → `docker/setup-buildx-action@v3` → `docker/login-action@v3` (GHCR, `GITHUB_TOKEN`) → `docker/metadata-action@v5` (tags `{{version}}`, `{{major}}.{{minor}}`, branch, `sha`, `latest`) → `docker/build-push-action@v6` (push; `provenance: false`, `sbom: false`, gha cache) → trivy → SARIF upload → SBOM → provenance attestation.
- Supply chain:
  - Trivy image scan: `aquasecurity/trivy-action@v0.36.0` (note the **`v`** prefix — the action publishes tags as `vX.Y.Z`; referencing `0.36.0` makes the job fail during *Set up job*), `severity: CRITICAL,HIGH`, `ignore-unfixed: true`, SARIF output. Auth via `TRIVY_USERNAME=github.actor` / `TRIVY_PASSWORD=GITHUB_TOKEN` (works while the package is still private).
  - SARIF → `github/codeql-action/upload-sarif@v3` (`continue-on-error: true` — GHAS is not on private repos) **and** kept as the `trivy-sarif` artifact.
  - SBOM: `anchore/sbom-action@v0` (syft, `spdx-json`), artifact `ratlab-demo-sbom`.
  - Provenance: `actions/attest-build-provenance@v4` (`subject-name` + digest, `push-to-registry: true`). **Not available for user-owned private repos**, so the step is gated on `github.event.repository.private == false` (skipped, not failed, while private; runs automatically once public).
- `imagetools inspect ghcr.io/wasim-hassan/ratlab-demo:<tag>` (or `docker buildx imagetools`) shows the attestation manifest.

## 03. One-time credential setup (manual)
1. **Write deploy key.** Generate the keypair + SOPS secret (see §03a), then in GitHub → *Repo → Settings → Deploy keys → Add deploy key*, paste the **public** key printed by the script and **✅ Allow write access**. With the `gh` CLI this is one command: `gh repo deploy-key add <pub-file> -R wasim-hassan/k8s-homelab-kvm --title flux-image-automation --allow-write`.
   - Public key (for reference):
     `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILFF6guelbTRKHkx7x9PJuTQf81Kz4IpWnFWaKL4iLer flux-image-automation@ratlab`
- (a) Regenerate/rotate the key at any time:
  ```bash
  cd /workspaces/k8s-homelab-kvm
  KEYDIR="$(mktemp -d)"; trap 'rm -rf "$KEYDIR"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C "flux-image-automation@ratlab" -f "$KEYDIR/id_ed25519"
  { printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: flux-git-write\n  namespace: flux-system\ntype: Opaque\nstringData:\n  identity: |\n'; sed 's/^/    /' "$KEYDIR/id_ed25519"; printf '  identity.pub: |\n'; sed 's/^/    /' "$KEYDIR/id_ed25519.pub"; printf '  known_hosts: |\n'; ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null | sed 's/^/    /'; } \
    > clusters/k8s-homelab/image-automation/git-write-secret.sops.yaml
  sops --encrypt --in-place clusters/k8s-homelab/image-automation/git-write-secret.sops.yaml
  cat "$KEYDIR/id_ed25519.pub"
  ```
- **Package visibility:** after the first successful CI push, set the GHCR package `ratlab-demo` to **public** (`https://github.com/users/<user>/packages/container/ratlab-demo/settings` → *Danger Zone → Change visibility → Public*). This lets the `ImageRepository` scan it and lets kubelet pull the image without a registry secret. **UI-only:** GHCR has **no REST/CLI endpoint** to change package visibility (a `PATCH` returns 404), so this can't be automated. (Alternative: keep it private and add a `dockerconfigjson` pull secret + `ImageRepository.spec.secretRef` — not used here.)

## 03b. Flux image-automation manifests
- Path: [`clusters/k8s-homelab/image-automation/`](../../clusters/k8s-homelab/image-automation) — `kustomization.yaml`, `git-repository.yaml`, `image-repository.yaml`, `image-policy.yaml`, `image-update-automation.yaml`, `git-write-secret.sops.yaml`.
- `FluxInstance.spec.components` gains `image-reflector-controller` + `image-automation-controller`.
- `GitRepository/flux-git-write` (source `v1`): same repo, `secretRef: flux-git-write`, **write** access.
- `ImageRepository` `ratlab-demo`: `ghcr.io/wasim-hassan/ratlab-demo`, `interval: 5m`.
- `ImagePolicy` `ratlab-demo`: `policy.semver.range: ">=0.1.0"`.
- `ImageUpdateAutomation` `flux-system`: `sourceRef: GitRepository/flux-git-write`, `update.strategy: Setters`, `push.branch: main`.
- Flux Kustomization `image-automation` (in [`clusters/k8s-homelab/image-automation.yaml`](../../clusters/k8s-homelab/image-automation.yaml)) depends on `flux-instance` and decrypts with `sops-age`.
- **Schema gotchas (v1):** there is **no** `spec.git.push.secretRef` (creds come from the `sourceRef` GitRepository); `spec.update.strategy` accepts **`Setters`** (not `Settle`).

## 04. The workload + setter marker
- [`apps/ratlab-demo/`](../../apps/ratlab-demo): `namespace.yaml` (PSS `restricted`), `serviceaccount.yaml` (no token automount), `deployment.yaml`, `service.yaml`, `httproute.yaml`, `referencegrant.yaml` (grants the route in `envoy-gateway-system`).
- The Deployment image line carries the marker Flux rewrites:
  `image: ghcr.io/wasim-hassan/ratlab-demo:0.1.0 # {"$imagepolicy": "flux-system:ratlab-demo"}`.

## 05. Verify the pipeline end-to-end
```bash
# Controllers
kubectl -n flux-system get deploy image-reflector-controller image-automation-controller

# The write source authenticates (needs 03 deploy key)
kubectl -n flux-system get gitrepository flux-git-write
# READY True once the write deploy key is added

# Registry scan + policy
kubectl -n flux-system get imagerepository ratlab-demo   # READY True (package public)
kubectl -n flux-system get imagepolicy ratlab-demo -o jsonpath="{.status.latestRef.image}"

# Automation + workload
kubectl -n flux-system get imageupdateautomation flux-system
kubectl -n ratlab-demo get pods
kubectl -n ratlab-demo rollout status deploy/ratlab-demo --timeout=90s
```
- **Cut a release:** `git tag -a v0.1.1 -m 'ratlab-demo v0.1.1' && git push origin v0.1.1`. CI builds/pushes; `ImagePolicy` resolves the new semver; `ImageUpdateAutomation` commits an updated tag to `main`; the `apps` Kustomization rolls it out. No manual YAML edit.
- App is reachable at `http://ratlab-demo.local` (host `/etc/hosts` → `192.168.123.11`).

## 06. Docs + commit
- ADR-0009 written; runbook 09 written; update `docs/system-inventory.md` (CI/CD + image-automation section), `docs/roadmap.md` (Phase 8 → done), `docs/README.md`, `AGENTS.md` (runbook index, architecture bullets).
- Commits: `feat(phase-8): CI/CD + Flux image automation` + follow-up schema fixes. Push from host.

## Notes / exceptions
- **No `push.secretRef` in v1** — the write `GitRepository` is the credential carrier; the operator-managed read `flux-system` source is left untouched.
- **Release-driven:** `ImagePolicy` matches **semver** (`>=0.1.0`), so only `vX.Y.Z` tags are deployed. Main-branch pushes produce `sha`/`latest` tags that no policy matches (by design).
- **`Setters`** is the only `update.strategy` value in v1.
- **GHCR package must be public** for the `ImageRepository` scrape and kubelet pull; otherwise ImagePolicy never resolves and the pod stays `ImagePullBackOff`.
- SARIF upload to code scanning is best-effort (`continue-on-error`) because private repos need GitHub Advanced Security; the SARIF is retained as a workflow artifact.
- **Action ref casing matters:** `aquasecurity/trivy-action` publishes tags as `vX.Y.Z`, so the ref must be `@v0.36.0`. A bare `@0.36.0` fails to resolve and aborts the job during *Set up job* (≈8 s) — before any build runs, so nothing is pushed.
- Provenance attestation is **skipped** (not failed) on user-owned private repos; it starts working automatically when the repo is public.
- The build embeds the version via `-ldflags -X main.version`; `/version` is the quick way to confirm a rollout actually changed the running image.
