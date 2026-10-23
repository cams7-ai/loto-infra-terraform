#!/usr/bin/env bash
# Lê a AWS e importa stacks para o state; não atualiza stacks.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
: "${AWS_PROFILE:?Exporte AWS_PROFILE}"
: "${AWS_REGION:?Exporte AWS_REGION}"
: "${EXPECTED_ACCOUNT_ID:?Exporte EXPECTED_ACCOUNT_ID}"
for tool in aws jq terraform; do command -v "$tool" >/dev/null; done
actual=$(aws sts get-caller-identity --query Account --output text)
[[ "$actual" == "$EXPECTED_ACCOUNT_ID" ]] || { echo 'Conta AWS incorreta' >&2; exit 1; }
mode=${1:-all}
[[ "$#" -le 1 && ( "$mode" == all || "$mode" == --scheduler-only ) ]] || { echo 'Uso: adopt.sh [--scheduler-only]' >&2; exit 1; }
mkdir -p prepared .local/adoption
apps=(mail-sender-aws gmail-reader-aws whatsapp-notify loto-bot loto-scheduler-aws)
keys=(mail gmail whatsapp bot scheduler)
names=("${MAIL_STACK:-mail-sender-aws}" "${GMAIL_STACK:-gmail-reader-aws}" "${WHATSAPP_STACK:-whatsapp-notify}" "${BOT_STACK:-loto-bot}" "${SCHEDULER_STACK:-loto-scheduler-aws}")
if [[ "$mode" == --scheduler-only ]]; then
  [[ -f terraform.tfvars.json ]] || { echo 'A migração requer terraform.tfvars.json existente' >&2; exit 1; }
  jq -e --arg account "$actual" --arg region "$AWS_REGION" '.account_id == $account and .region == $region and (.stack_names.scheduler == null) and (.parameters.scheduler == null)' terraform.tfvars.json >/dev/null
  terraform state list > .local/adoption/state.txt
  for key in mail gmail whatsapp bot; do
    grep -Fxq "aws_cloudformation_stack.$key" .local/adoption/state.txt
  done
  cp terraform.tfvars.json .local/adoption/before-scheduler.tfvars.json
  terraform state pull > .local/adoption/before-scheduler.tfstate.json
  cp terraform.tfvars.json .local/adoption/config.json
  apps=(loto-scheduler-aws)
  keys=(scheduler)
  names=("${SCHEDULER_STACK:-loto-scheduler-aws}")
else
  [[ ! -e terraform.tfvars.json && ! -e releases.auto.tfvars.json ]] || { echo 'Configuração já existe; preserve-a. Adoção é inicial.' >&2; exit 1; }
  jq -n --arg account "$actual" --arg region "$AWS_REGION" '{account_id:$account,region:$region,stack_names:{},parameters:{}}' > .local/adoption/config.json
fi
for i in "${!apps[@]}"; do
  app=${apps[$i]}; key=${keys[$i]}; name=${names[$i]}
  aws cloudformation describe-stacks --stack-name "$name" > ".local/adoption/$key.json"
  jq -e '.Stacks[0].StackStatus | IN("CREATE_COMPLETE","UPDATE_COMPLETE","IMPORT_COMPLETE","UPDATE_ROLLBACK_COMPLETE")' ".local/adoption/$key.json" >/dev/null
  jq '.Stacks[0].Parameters | map({key:.ParameterKey,value:.ParameterValue}) | from_entries' ".local/adoption/$key.json" > ".local/adoption/$key.params.json"
  if [[ "$key" == mail ]]; then
    : "${SES_FROM:?Exporte SES_FROM para recuperar o parâmetro NoEcho}"
    jq --arg email "$SES_FROM" '.SesFrom=$email' ".local/adoption/$key.params.json" > .local/adoption/p.tmp
    mv .local/adoption/p.tmp ".local/adoption/$key.params.json"
  fi
  if [[ "$key" == scheduler ]]; then
    : "${SCHEDULER_MAIL_TO:?Exporte SCHEDULER_MAIL_TO para recuperar MailTo (NoEcho)}"
    jq --arg email "$SCHEDULER_MAIL_TO" '.MailTo=$email' ".local/adoption/$key.params.json" > .local/adoption/p.tmp
    mv .local/adoption/p.tmp ".local/adoption/$key.params.json"
  fi
  jq -e 'all(.[]; . != "****" and . != "*****")' ".local/adoption/$key.params.json" >/dev/null || { echo "Parâmetro mascarado em $name; recupere-o antes da importação" >&2; exit 1; }
  aws cloudformation get-template --stack-name "$name" --template-stage Original --output json |
    jq -r '.TemplateBody | if type == "string" then . else tojson end' > "prepared/$app.yaml"
  jq --arg k "$key" --arg name "$name" --slurpfile p ".local/adoption/$key.params.json" '.stack_names[$k]=$name | .parameters[$k]=$p[0]' .local/adoption/config.json > .local/adoption/c.tmp
  mv .local/adoption/c.tmp .local/adoption/config.json
done
cp .local/adoption/config.json terraform.tfvars.json
terraform init
for i in "${!keys[@]}"; do
  addr="aws_cloudformation_stack.${keys[$i]}"
  if ! terraform state list | grep -Fxq "$addr"; then
    terraform import "$addr" "${names[$i]}"
  fi
done
terraform plan -out=.local/adoption.tfplan
echo 'Adoção concluída. Revise o plano; não aplique mudanças inesperadas.'
