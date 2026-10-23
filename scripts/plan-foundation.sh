#!/usr/bin/env bash
# Reutiliza os contêineres de secrets existentes antes de planejar a fundação.
# Não lê valores secretos e não aplica o plano. Execute após terraform init.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ "$#" == 0 ]] || { echo 'Uso: bash scripts/plan-foundation.sh (usa as variáveis de foundation/)' >&2; exit 1; }
for tool in aws jq terraform; do command -v "$tool" >/dev/null; done
export AWS_PAGER=''
export TF_INPUT=0
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Console usa os mesmos defaults, TF_VAR_* e arquivos tfvars do plano/import.
config=$(terraform -chdir=foundation console <<'TF'
jsonencode({account_id = var.account_id, region = var.region, name = var.name})
TF
)
config=$(jq -er 'fromjson' <<< "$config")
account=$(jq -er '.account_id' <<< "$config")
region=$(jq -er '.region' <<< "$config")
prefix=$(jq -er '.name' <<< "$config")
actual=$(aws sts get-caller-identity --region "$region" --query Account --output text)
[[ "$actual" == "$account" ]] || { echo 'Conta AWS diferente da configuração da fundação' >&2; exit 1; }
if ! terraform -chdir=foundation state list > "$work/state.txt" 2> "$work/state-error.txt"; then
  if grep -Fq 'No state file was found!' "$work/state-error.txt"; then
    : > "$work/state.txt"
  else
    cat "$work/state-error.txt" >&2
    exit 1
  fi
fi
backup_done=false

keys=(application gmail)
names=("$prefix/application" "$prefix/gmail-oauth-token")
for i in "${!keys[@]}"; do
  address="aws_secretsmanager_secret.${keys[$i]}"
  name=${names[$i]}
  if ! aws secretsmanager describe-secret --region "$region" --secret-id "$name" --output json \
    > "$work/secret.json" 2> "$work/error.txt"; then
    # Só ausência confirmada permite criar; falhas de permissão/rede interrompem.
    if grep -Fq '(ResourceNotFoundException)' "$work/error.txt"; then
      echo "Secret $name ausente; o Terraform verificará sua criação."
      continue
    fi
    cat "$work/error.txt" >&2
    exit 1
  fi
  arn=$(jq -er --arg name "$name" --arg account "$account" --arg region "$region" \
    'select(.Name == $name) | .ARN | select(startswith("arn:aws:secretsmanager:" + $region + ":" + $account + ":secret:"))' "$work/secret.json")
  if jq -e '.DeletedDate != null' "$work/secret.json" >/dev/null; then
    echo "Restaurando secret $name com exclusão agendada."
    aws secretsmanager restore-secret --region "$region" --secret-id "$arn" --output json > /dev/null
    aws secretsmanager describe-secret --region "$region" --secret-id "$arn" --output json > "$work/secret.json"
    jq -e '.DeletedDate == null' "$work/secret.json" >/dev/null || {
      echo "Secret $name ainda em restauração; execute novamente antes de planejar." >&2; exit 1;
    }
  fi
  if grep -Fxq "$address" "$work/state.txt"; then
    echo "Secret $name já gerenciada no state."
    continue
  fi
  if [[ "$backup_done" == false && -s "$work/state.txt" ]]; then
    mkdir -p .local
    backup=$(mktemp .local/foundation-before-secret-import.XXXXXX.tfstate)
    terraform -chdir=foundation state pull > "$backup"
    backup_done=true
    echo "Backup do state: $backup"
  fi
  echo "Importando secret existente $name."
  terraform -chdir=foundation import -input=false "$address" "$arn"
done

terraform -chdir=foundation plan -input=false -out=foundation.tfplan
