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
  namespace.yaml       # namespace omi, pod-security baseline, gitlab-registry pull secret ref
  data.yaml            # datalaag + infra: redis/qdrant/typesense (StatefulSets+PVCs, longhorn),
                       #   CNPG Cluster omi-db (Postgres jobstore, 2 instances),
                       #   omi-firebase-emulator (auth+firestore, PVC-persistent),
                       #   Job omi-jobstore-migrate, PVCs omi-emulator-data + omi-storage-data,
                       #   NetworkPolicy omi-app (omi + kube-system + cnpg-system ingress)
  app.yaml             # Deployments omi-backend x2, omi-desktop-backend x2, omi-pusher
                       #   + Services + ConfigMap omi-env (env incl. emulator hosts, jobstore, local storage)
  ingress.yaml         # api.omi.euraika.dev regex paths -> backend/desktop/pusher, cert via cert-manager
  secrets.md           # MANUAL secret bootstrap commands (never commit values)
  secret-locations.md  # WAAR secrets leven (1Password items + cluster Secrets), nooit waarden
  kustomization.yaml
```

## Data- en auth-laag (selfhosted, geen Google ADC)

- **Firestore + Auth**: `omi-firebase-emulator` Deployment (auth 9099, firestore 8080,
  project `demo-omi-local`). `FIRESTORE_EMULATOR_HOST`/`FIREBASE_AUTH_EMULATOR_HOST` in
  `omi-env` zorgen dat álle clients (ook customer-data) naar de emulator gaan — zonder
  deze variabele vallen ze terug op ADC en zie je `DefaultCredentialsError`-warnings.
  Persistentie: 60s export-loop via Emulator Hub `POST /_admin/export` naar
  `/emulator-data/export` op PVC `omi-emulator-data` (50Gi) + `--import` bij startup.
  De Firestore-emulator is een JVM met de hele DB in heap: 8Gi limit + `JAVA_TOOL_OPTIONS=-Xmx6g`.
- **Postgres jobstore**: CNPG `Cluster omi-db` (2 instances, longhorn 20Gi). Het
  app-Secret `omi-db-app` (key `uri`) levert `JOBSTORE_PG_DSN`; `BATCH_JOBSTORE_MODE=shadow`
  spiegelt de batch jobstore erheen. Schema-migraties: Job `omi-jobstore-migrate`
  (draait `database.jobstore.migrate` uit de backend-image, runAsUser 10001).
  Let op: een Job is immutable — bij een nieuwe image moet je hem verwijderen, Argo maakt
  hem opnieuw aan.
- **Object storage**: lokale files op PVC `omi-storage-data` (RWX, gemount als
  `/omi-state`), public URLs via `/_local/storage` (ingress → backend, zie `main.py`).
  Gate: `OMI_LOCAL_STORAGE_ALLOW_SELFHOSTED=1` in `omi-env`.
- **NetworkPolicy `omi-app`** staat ingress toe vanuit `omi`, `kube-system` (ingress-nginx)
  én `cnpg-system` — zonder die laatste kan de CNPG-operator `omi-db:8000/pg/status` niet
  bereiken en blijft de Cluster (en dus de Argo-sync) op Unknown/Progressing hangen.
- **Stage**: `OMI_ENV_STAGE=selfhosted` (toegevoegd aan `VALID_STAGES` in
  `backend/utils/env_loader.py`; stage file `.env.selfhosted` mag ontbreken — env komt
  uit ConfigMap/Secret). Batch namespaces accepteren `batch_pipeline_selfhosted`.

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

1. Push to a branch of `git.euraika.net/euraika/omi` (PAT uit 1Password item
   `euraika gitlab token`; zie `secret-locations.md`) → pipeline runs
   `build-image-backend` / `build-image-desktop-backend` / `build-image-pusher`
   (on `backend/**` or `.gitlab-ci.yml` changes) → images tagged with
   `$CI_COMMIT_SHORT_SHA` (**8 chars**, e.g. `7deed55f`).
2. Edit `gitops-onprem/omi/app.yaml` + `data.yaml` image tags to the new short sha
   and push. Argo CD Application `omi` (automated sync, selfHeal, prune) rolls the
   Deployments in namespace `omi`.
   - De migrate-Job is immutable: Argo faalt anders met `spec.template: Invalid value`.
     Verwijder hem handmatig (`kubectl -n omi delete job omi-jobstore-migrate`), Argo
     maakt hem opnieuw aan met de nieuwe image.
3. CI-built macOS builds point at this backend **by default**:
   `desktop/macos/ci/gitlab-build.sh` bakes `OMI_PYTHON_API_URL=https://api.omi.euraika.dev`,
   `OMI_DESKTOP_API_URL=.../desktop`, `OMI_AUTH_API_URL=...` and `OMI_ENV_STAGE=selfhosted`
   into the bundle `.env` (override via `OMI_CI_*` env vars in the pipeline).

## Secrets

See `secrets.md` — create them once with kubectl before the first sync
(`ENCRYPTION_SECRET`, `ADMIN_KEY`, redis/typesense/qdrant keys, LLM key, ACME account).
**Never commit values.** `secret-locations.md` somt op waar elke secret leeft
(1Password items + cluster Secrets + Vault key voor het Argo CD repo-token).

## Verificatie na een deploy

```sh
kubectl --context onprem -n argocd get application omi          # Synced Healthy
kubectl --context onprem -n omi get pods                        # alles 1/1 Running, image = gepinde sha
kubectl --context onprem -n omi logs deploy/omi-backend | grep -ci DefaultCredentialsError   # 0
curl -sk --resolve api.omi.euraika.dev:443:<ingress-ip> https://api.omi.euraika.dev/v1/health # {"status":"ok"}
curl -sk --resolve api.omi.euraika.dev:443:<ingress-ip> https://api.omi.euraika.dev/desktop/health
curl -sk --resolve api.omi.euraika.dev:443:<ingress-ip> -X POST https://api.omi.euraika.dev/v1/auth/local-dev/custom-token -H 'Content-Type: application/json' -d '{"uid":"check"}'  # 200 + JWT
```
