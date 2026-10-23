#!/usr/bin/env bash
# Compila e publica artefatos; NÃO atualiza as stacks.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
project=$PWD
: "${SOURCE_ROOT:?Diretório com os cinco repositórios}"
: "${ARTIFACT_BUCKET:?Bucket S3 privado existente na mesma região}"
: "${AWS_PROFILE:?Exporte AWS_PROFILE}"
: "${AWS_REGION:?Exporte AWS_REGION}"
: "${EXPECTED_ACCOUNT_ID:?Exporte EXPECTED_ACCOUNT_ID}"
for tool in aws sam docker git jq sha256sum terraform; do command -v "$tool" >/dev/null; done
[[ $(aws sts get-caller-identity --query Account --output text) == "$EXPECTED_ACCOUNT_ID" ]]
docker info >/dev/null
aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$EXPECTED_ACCOUNT_ID"
bucket_region=$(aws s3api get-bucket-location --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$EXPECTED_ACCOUNT_ID" --query LocationConstraint --output text)
[[ "$bucket_region" != None ]] || bucket_region=us-east-1
[[ "$bucket_region" == "$AWS_REGION" ]] || { echo 'Bucket em região diferente' >&2; exit 1; }
mkdir -p dist prepared .local
for app in mail-sender-aws gmail-reader-aws whatsapp-notify loto-bot loto-scheduler-aws; do
  repo="$SOURCE_ROOT/$app"
  [[ -z $(git -C "$repo" status --porcelain) ]] || { echo "$repo tem alterações; faça commit antes da release." >&2; exit 1; }
  git -C "$repo" rev-parse --verify HEAD >/dev/null
  [[ "$(git -C "$repo" rev-parse --show-toplevel)" == "$(realpath "$repo")" ]] || { echo "Esperado repositório independente: $repo" >&2; exit 1; }
  [[ -f "$repo/template.yaml" ]]
done
printf '{}\n' > .local/artifacts.json
for app in mail-sender-aws gmail-reader-aws loto-scheduler-aws; do
  repo="$SOURCE_ROOT/$app"
  revision=$(git -C "$repo" rev-parse HEAD)
  build_args=()
  if [[ "$app" == loto-scheduler-aws ]]; then
    runtime=$(jq -er '.parameters.scheduler.Runtime // "python3.12"' terraform.tfvars.json)
    [[ "$runtime" =~ ^python3\.(12|13|14)$ ]] || { echo 'Runtime do scheduler não suportado' >&2; exit 1; }
    build_args=(--parameter-overrides "Runtime=$runtime")
  fi
  (cd "$repo" && SAM_CLI_TELEMETRY=0 sam build --use-container --template-file template.yaml --build-dir "$project/dist/$app/$revision" "${build_args[@]}")
  if [[ "$app" == loto-scheduler-aws ]]; then
    # Imports isolados no Linux/Python do runtime, antes de publicar qualquer pacote do scheduler.
    docker run --rm --entrypoint "$runtime" \
      -v "$project/dist/$app/$revision/SchedulerFunction:/artifact:ro" \
      -v "$repo/scripts/check_artifact.py:/check_artifact.py:ro" \
      "public.ecr.aws/sam/build-$runtime:latest" -I /check_artifact.py /artifact
  fi
  sam package --template-file "$project/dist/$app/$revision/template.yaml" --s3-bucket "$ARTIFACT_BUCKET" --s3-prefix "$app/releases/$revision" --output-template-file "$project/prepared/$app.yaml"
done
for pair in whatsapp:whatsapp-notify bot:loto-bot; do
  key=${pair%%:*}; app=${pair#*:}; repo="$SOURCE_ROOT/$app"
  revision=$(git -C "$repo" rev-parse HEAD)
  zip="$project/dist/$app-$revision.zip"
  git -C "$repo" archive --format=zip --output="$zip" HEAD
  sha=$(sha256sum "$zip" | cut -d' ' -f1)
  object="$app/releases/$revision-$sha.zip"
  aws s3 cp "$zip" "s3://$ARTIFACT_BUCKET/$object" --only-show-errors
  cp "$repo/template.yaml" "prepared/$app.yaml"
  jq --arg key "$key" --arg bucket "$ARTIFACT_BUCKET" --arg object "$object" --arg sha "$sha" '.[$key]={ArtifactBucket:$bucket,ArtifactKey:$object,ArtifactSha256:$sha}' .local/artifacts.json > .local/a.tmp
  mv .local/a.tmp .local/artifacts.json
done
jq '{artifact_parameters:.}' .local/artifacts.json > releases.auto.tfvars.json
for app in mail-sender-aws gmail-reader-aws whatsapp-notify loto-bot loto-scheduler-aws; do
  aws cloudformation validate-template --template-body "file://$project/prepared/$app.yaml" >/dev/null
done
terraform fmt -check
terraform validate
echo 'Artefatos preparados. Execute terraform plan e revise antes do apply.'
