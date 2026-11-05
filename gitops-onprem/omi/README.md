# Omi self-hosted stack on the onprem cluster (euraika.dev)

Argo CD Application `omi` (namespace `omi`) deploys the Omi backend stack onto the
onprem RKE2 cluster, exposed at **`https://api.omi.euraika.dev`** (main backend +
desktop backend behind one Ingress) and **`wss://api.omi.euraika.dev`** for the
pusher WebSocket. Images come from the GitLab container registry
(`git.euraika.net:5050/euraika/omi/{backend,desktop-backend,pusher}:<sha>`), built by
`.gitlab-ci.yml` jobs `build-image-*` in `git.euraika.net/euraika/omi`.

## Layout

```
gitops-onprem/omi/
  namespace.yaml     # namespace omi, pod-security baseline, gitlab-registry pull secret ref
  data.yaml          # redis, qdrant, typesense (StatefulSets + Services + PVCs, longhorn)
  app.yaml           # backend, desktop-backend, pusher Deployments/Services + ConfigMap env
  ingress.yaml       # api.omi.euraika.dev -> backend :8080, cert via cert-manager
  secrets.md         # MANUAL secret bootstrap commands (never commit values)
  kustomization.yaml
```

Cluster wiring (in `euraika/infrastructure-platform`):

- `gitops/clusters/onprem-omi.yaml` — AppProject `omi` + Application `omi`
  (source: `git.euraika.net/euraika/omi.git`, path `gitops-onprem/omi`).
- `gitops/clusters/root-onprem.yaml` — add `onprem-omi.yaml` to the `include` list,
  then `kubectl --context onprem apply -f root-onprem.yaml` once by hand.
- token-rotator `targets-registry.json` — add namespace `omi` so `gitlab-registry`
  pull secret is rotated there.
- Argo CD repo access for `euraika/omi`: add an ExternalSecret `repo-omi` in
  `onprem/platform/argocd-repos.yaml` + a Vault key `platform/argocd-onprem-omi`
  (deploy token on the `euraika/omi` project), plus a read line in
  `vault-policies/argocd-repos.hcl`.

## DNS / TLS

`api.omi.euraika.dev` must point at the ingress-nginx addresses
(192.168.1.121/.168/.71/.72/.73 — same as app.chatioo.net). TLS is Let's Encrypt
HTTP-01 via a namespace-local Issuer `omi-letsencrypt` (same pattern as chatioo),
so no wildcard cert or cluster-wide issuer is needed.

## Deploy flow

1. Push to a branch of `git.euraika.net/euraika/omi` → pipeline runs
   `build-image-backend` / `build-image-desktop-backend` / `build-image-pusher`
   (on `backend/**` changes) → images tagged with `$CI_COMMIT_SHORT_SHA`.
2. Edit `gitops-onprem/omi/app.yaml` image tags to the new sha (or use kustomize
   `images:` override — see kustomization.yaml) and push.
3. Argo CD Application `omi` (automated sync, selfHeal, no prune) rolls the
   Deployments in namespace `omi`.
4. Point the CI-built macOS app at it: in `desktop/macos/ci/gitlab-build.sh` set
   `OMI_DESKTOP_API_URL=https://api.omi.euraika.dev` and
   `OMI_PYTHON_API_URL=https://api.omi.euraika.dev` in the bundle `.env`.

## Secrets

See `secrets.md` — create them once with kubectl before the first sync
(`ENCRYPTION_SECRET`, `ADMIN_KEY`, redis/typesense/qdrant keys, Firebase SA or
emulator hosts, LLM keys). Never commit values.
