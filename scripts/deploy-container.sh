#!/usr/bin/env bash
# Build container/, push to GCR, deploy to Cloud Run, and write the resulting
# URL back into .env as CLOUD_RUN_URL. Reads GCP_PROJECT, GCP_REGION, API_KEY
# from .env.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Run: cp .env.example .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${GCP_PROJECT:?set GCP_PROJECT in .env}"
: "${GCP_REGION:?set GCP_REGION in .env}"
: "${API_KEY:?set API_KEY in .env}"

IMAGE="gcr.io/${GCP_PROJECT}/code-service"

echo "==> building image $IMAGE"
gcloud builds submit "$ROOT/container" --tag "$IMAGE" --project "$GCP_PROJECT"

# PWSH_CMD: TokenTacticsV2 device-code flow. Get-EntraIDToken Write-Outputs the
# auth response (containing the "enter the code XXXXX" message the front-end
# regex matches), then $global:response holds the token after auth completes.
PWSH_CMD=$(cat <<'PWSH'
$InformationPreference = "Continue"
Write-Host "Loading module..."
Set-Location /opt/ttv
Import-Module ./TokenTactics.psd1
Write-Host "Requesting device code..."
Get-EntraIDToken -Client MSGraph
if ($global:response) {
  $global:response | ConvertTo-Json -Depth 5 | Out-File /app/logs/response.json -Encoding utf8
}
Write-Host "Done."
PWSH
)

ENV_YAML="$(mktemp)"
trap 'rm -f "$ENV_YAML"' EXIT

cat > "$ENV_YAML" <<EOF
API_KEY: "$API_KEY"
PWSH_CMD: |
$(printf '%s\n' "$PWSH_CMD" | sed 's/^/  /')
EOF

echo "==> deploying code-service to Cloud Run ($GCP_REGION)"
gcloud run deploy code-service \
  --image "$IMAGE" \
  --region "$GCP_REGION" \
  --project "$GCP_PROJECT" \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --min-instances 1 \
  --env-vars-file "$ENV_YAML"

URL=$(gcloud run services describe code-service \
  --region "$GCP_REGION" \
  --project "$GCP_PROJECT" \
  --format='value(status.url)')

CODE_URL="${URL}/code"

echo "==> writing CLOUD_RUN_URL=$CODE_URL to .env"
if grep -q '^CLOUD_RUN_URL=' "$ENV_FILE"; then
  # portable in-place sed (mac + linux)
  sed -i.bak "s|^CLOUD_RUN_URL=.*|CLOUD_RUN_URL=$CODE_URL|" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
else
  printf '\nCLOUD_RUN_URL=%s\n' "$CODE_URL" >> "$ENV_FILE"
fi

echo
echo "✓ deployed: $URL"
echo "✓ .env updated. Next: npm run deploy:firebase"
