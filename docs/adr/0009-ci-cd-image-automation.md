# ADR-0009 — CI/CD + Flux image automation

- **Status:** Accepted (2026-10-16, Phase 8)
- **Deciders:** project owner
- **Context:** Phases 0–7b gave the cluster a GitOps delivery path (Flux) plus
  commit-time (trivy CLI) and runtime (Trivy Operator) scanning. But images were
  still built by hand and **bumped by hand** — the podinfo remediation
  ([ADR-0008](0008-trivy-operator.md)) was a manual `deployment.yaml` edit. There
  was no build pipeline and no supply-chain artifacts (SBOM/provenance), and the
  deploy loop had a human in the middle. Phase 8 closes that loop: **commit →
  CI builds → Flux deploys**.

---

## Decision

Build the image in **GitHub Actions**, push to **GHCR**, and let **Flux image
automation** write new tags back to git.

### 1. A workload we actually build — `ratlab-demo`
- A tiny FOSS **Go** HTTP server ([`images/ratlab-demo/`](../../images/ratlab-demo))
  exposing `/` (version + hostname), `/version` (JSON), `/healthz`, `/readyz`.
- Multi-stage build: `golang:1.23-alpine` → **`scratch`**, static binary, `USER
  65532:65532`, single `linux/amd64` platform. Minimal attack surface and
  trivially PSS-`restricted`-compliant (matches the Phase 7 posture).
- Deployed as `apps/ratlab-demo` (Deployment/Service/HTTPRoute), routed at
  `ratlab-demo.local` through the existing Envoy Gateway.

### 2. CI: GitHub Actions → GHCR
- Workflow [`.github/workflows/ci.yaml`](../../.github/workflows/ci.yaml) on push
  to `main` (paths `images/ratlab-demo/**`), on `v*` tags, on PRs and manually.
- **Buildx** build + push to `ghcr.io/wasim-hassan/ratlab-demo`; tags via
  `docker/metadata-action`: **semver** (`{{version}}`, `{{major}}.{{minor}}`) from
  git tags, `sha`, `edge`/`latest`. Pushes use the run's `GITHUB_TOKEN`
  (`packages: write`) — no long-lived registry credential.
- **Supply chain (left of Phase 7):**
  - `trivy` image scan (`aquasecurity/trivy-action@v0.36.0`, `severity:
    CRITICAL,HIGH`, `ignore-unfixed: true`) → SARIF, plus a retained artifact.
    Code-scanning upload is `continue-on-error` (GHAS is not enabled on a private
    repo; the SARIF artifact is the durable record).
  - **SBOM** via `anchore/sbom-action` (syft, SPDX-JSON) uploaded as an artifact.
  - **Build provenance** attestation via `actions/attest-build-provenance@v4`
    (Sigstore keyless, pushed to the registry). Provenance is **not available
    for user-owned private repositories**, so the step is gated on
    `github.event.repository.private == false` and activates automatically once
    the repo is made public.
- GitHub Actions was chosen over a self-hosted FOSS runner (Gitea
  Actions/Woodpecker) as the roadmap-sanctioned, zero-extra-infrastructure option
  for a 2-node lab. GitHub is a hosted service here, not a component in the
  cluster; the local workspace remains FOSS-only.

### 3. Flux image automation (write-back)
- The **`image-reflector-controller`** and **`image-automation-controller`** are
  added to `FluxInstance.spec.components`
  ([`flux-instance.yaml`](../../clusters/k8s-homelab/flux-instance/fluxinstance.yaml)).
- Manifests in [`clusters/.../image-automation/`](../../clusters/k8s-homelab/image-automation):
  - `ImageRepository` `ratlab-demo` — scans GHCR every 5m.
  - `ImagePolicy` `ratlab-demo` — **semver `>=0.1.0`** (latest release wins).
  - `ImageUpdateAutomation` `flux-system` — `update.strategy: Setters`, commits
    back to `main` via the marker in the Deployment.
  - **Write `GitRepository`** `flux-git-write` — a dedicated source using the
    **write deploy key**, used as the automation's `sourceRef`.
- The Deployment carries the kyaml setter marker:
  `image: ghcr.io/wasim-hassan/ratlab-demo:0.1.0 # {"$imagepolicy": "flux-system:ratlab-demo"}`.
  Flux rewrites the tag in git; the `apps` Kustomization then rolls it out.

### 4. Write-back credential (why a second key)
- In `image.toolkit.fluxcd.io/v1` there is **no `git.push.secretRef`** — push
  credentials come from the **`sourceRef` GitRepository**. The bootstrap key is
  **read-only**, and swapping it would risk losing read access.
- Therefore a **separate** SSH deploy key with **write** access is added to
  GitHub and stored **SOPS-encrypted** as `Secret/flux-git-write` (keys
  `identity`, `identity.pub`, `known_hosts`). The read path (`flux-system`
  GitRepository, operator-managed) is untouched.
- Consistent with the repo's secrets hygiene: only ciphertext is committed,
  decrypted by Flux with the `sops-age` key.

---

## Consequences

- **Positive:** The full loop is automated end-to-end and release-driven (tag
  `vX.Y.Z` → CI builds → Flux updates the tag in git → cluster rolls). Supply-chain
  artifacts (SBOM, provenance attestation, trivy SARIF) are produced per build,
  extending Phase 7/7b left-to-right. The write credential is least-privilege
  (one repo, write) and encrypted at rest in git.
- **Negative:** Adds `image-reflector` + `image-automation` controllers to the
  cluster (small; Flux-native). GitHub Actions/GHCR are hosted dependencies
  (accepted; not in-cluster). Image automation **pushes to `main`**, so branch
  protection must allow the deploy-key identity, and a `vX.Y.Z` tag is required to
  cut a release (documented in the runbook).
- **Neutral / manual steps (both done):** (a) the generated **public** key is
  added as a **write** deploy key (done via `gh` as `flux-image-automation`);
  (b) the **GHCR package visibility** must be set to **public** so the
  ImageRepository and kubelet can pull without a registry secret. Step (b) is
  **UI-only**: GHCR has **no REST/CLI endpoint to change package visibility**,
  so it cannot be automated. Until (b), `ratlab-demo` stays `ImagePullBackOff`
  and the ImageRepository scan returns `DENIED` (this was the observed state
  before the manual step).

## References
- [runbook 09](../runbooks/09-ci-cd-image-automation.md) (execution + verification)
- [system-inventory — CI/CD](../system-inventory.md#cicd--image-automation-phase-8)
- [roadmap — Phase 8](../roadmap.md#phase-8--cicd--image-automation)
- [ADR-0007](0007-security-hardening.md) · [ADR-0008](0008-trivy-operator.md)
- Flux image automation: <https://fluxcd.io/flux/guides/image-update/>
