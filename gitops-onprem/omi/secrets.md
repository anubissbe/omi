# Omi onprem — Secrets aanmaken (eenmalig, vóór de eerste Argo CD sync)

Maak de Secrets met de hand aan in namespace `omi`; toon of commit nooit een waarde.
Zie `secret-locations.md` voor de actuele locaties (1Password items, Vault key voor
het Argo CD repo-token, cluster Secrets).

## 1. Namespace + pull-secret

```sh
kubectl --context onprem create ns omi
# pull-secret kopiëren van een bestaande namespace (zelfde pull-onprem token),
# zonder de waarde te tonen:
kubectl --context onprem -n awatif get secret gitlab-registry -o json \
  | kubectl --context onprem -n omi apply -f -
# (de token-rotator voegt namespace omi toe aan targets-registry.json en houdt
#  het secret daarna actueel)
```

## 2. Secret omi-data (datalaag-wachtwoorden)

```sh
umask 077; f=$(mktemp)
{
  echo "REDIS_PASSWORD=$(openssl rand -hex 24)"
  echo "TYPESENSE_API_KEY=$(openssl rand -hex 24)"
  echo "QDRANT_API_KEY=$(openssl rand -hex 24)"
} > "$f"
kubectl --context onprem -n omi create secret generic omi-data --from-env-file="$f"
rm -f "$f"
```

## 3. Secret omi-secrets (app runtime)

```sh
umask 077; f=$(mktemp)
{
  echo "ENCRYPTION_SECRET=$(openssl rand -base64 48)"
  echo "ADMIN_KEY=$(openssl rand -hex 32)"
  echo "REDIS_DB_PASSWORD=<zelfde als omi-data REDIS_PASSWORD>"
  echo "TYPESENSE_API_KEY=<zelfde als omi-data TYPESENSE_API_KEY>"
  # LLM: Mistral (of eigen endpoint) via OPENAI-compatibele gateway
  echo "OPENAI_API_KEY=<mistral api key>"
  echo "OPENAI_BASE_URL=https://api.mistral.ai/v1"
  # STT: eigen Deepgram-compatibele endpoint of hosted key
  # echo "DEEPGRAM_SELF_HOSTED_URL=http://omi-stt:8080"
  # echo "DEEPGRAM_API_KEY=<key>"
  # Auth/Firestore: op onprem via de Firebase emulator-suite in de namespace
  # (omi-firebase-emulator, project demo-omi-local) — deze staan in omi-env.
  # Eigen Firebase project (SA JSON) kan als alternatief:
  # echo "SERVICE_ACCOUNT_JSON=<json, één regel>"
} > "$f"
kubectl --context onprem -n omi create secret generic omi-secrets --from-env-file="$f"
rm -f "$f"
```

## 4. Firebase emulator (selfhosted, geen Google Cloud nodig)

De emulator-suite draait als Deployment `omi-firebase-emulator` in namespace `omi`
(Auth 9099, Firestore 8080, UI 4000, project `demo-omi-local`). De env-variabelen
`FIRESTORE_EMULATOR_HOST`, `FIREBASE_AUTH_EMULATOR_HOST`, `FIREBASE_PROJECT_ID`
staan in ConfigMap `omi-env` (app.yaml) — zonder `FIRESTORE_EMULATOR_HOST` vallen
de Firestore clients terug op ADC en krijg je `DefaultCredentialsError`-warnings.
Data is persistent: 60s export-loop naar `/emulator-data/export` op PVC
`omi-emulator-data` + `--import` bij pod-start.

Lokale sign-in voor dev/test:

```sh
curl -X POST https://api.omi.euraika.dev/v1/auth/local-dev/custom-token \
  -H 'Content-Type: application/json' -d '{"uid":"bert","email":"bert@euraika.net"}'
```

## 4b. Postgres jobstore (CNPG)

`Cluster omi-db` (data.yaml) genereert zelf het app-Secret `omi-db-app` met key `uri`
(= `JOBSTORE_PG_DSN`, incl. wachtwoord) — **niet handmatig aanmaken**. De DSN wordt
in de Deployments geïnjecteerd via `secretKeyRef omi-db-app/uri` en wint boven de
IAM-triple (`JOBSTORE_PG_HOST/DATABASE/USER`). Schema-migraties draaien via Job
`omi-jobstore-migrate`; bij een nieuwe backend-image deze Job verwijderen (immutable),
Argo maakt hem opnieuw aan.

## 5. cert-manager ACME account

```sh
umask 077; f=$(mktemp)
echo "tls.key=$(openssl genrsa 2048 | base64 -w0)" > "$f"
kubectl --context onprem -n omi create secret generic omi-letsencrypt-account --from-env-file="$f"
rm -f "$f"
```

## Roteren

Waarde vervangen in het Secret, daarna de Deployments herstarten:

```sh
kubectl --context onprem -n omi rollout restart deploy/omi-backend deploy/omi-desktop-backend deploy/omi-pusher
```
