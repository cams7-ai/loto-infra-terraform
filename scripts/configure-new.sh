#!/usr/bin/env bash
# Gera configuração inicial local; não aplica Terraform nem lê valores de secrets.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
: "${EXPECTED_ACCOUNT_ID:?Exporte EXPECTED_ACCOUNT_ID}"
: "${AWS_REGION:?Exporte AWS_REGION}"
: "${SCHEDULER_MAIL_TO:?Exporte SCHEDULER_MAIL_TO}"
for tool in terraform jq; do command -v "$tool" >/dev/null; done
for config in terraform.tfvars.json releases.auto.tfvars.json maintenance.auto.tfvars.json; do
  [[ ! -e "$config" ]] || { echo "Configuração já existe: $config; preserve-a." >&2; exit 1; }
done
foundation=$(terraform -chdir=foundation output -json configuration)
jq -e --arg account "$EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" \
  '.account_id == $account and .region == $region' <<< "$foundation" >/dev/null || {
  echo 'Conta/região da fundação diferem do ambiente exportado.' >&2; exit 1;
}
jq -e 'all([.account_id, .region, .name, .vpc_id, .subnet_id, .route_table_id,
  .integration_security_group_id, .lambda_endpoint_sg_id, .artifact_bucket, .key_name,
  .ssh_ipv6_cidr, .ami_id, .application_secret_arn, .gmail_secret_arn,
  .bets_table, .executions_table, .ses_from][]; type == "string" and length > 0)' \
  <<< "$foundation" >/dev/null || { echo 'Outputs incompletos; conclua o apply da fundação.' >&2; exit 1; }
mkdir -p .local
config=$(mktemp .local/new-config.XXXXXX)
trap 'rm -f -- "$config"' EXIT
jq --argjson f "$foundation" --arg to "$SCHEDULER_MAIL_TO" '
  .account_id = $f.account_id | .region = $f.region |
  .stack_names = {mail:($f.name+"-mail"), gmail:($f.name+"-gmail"),
    whatsapp:($f.name+"-whatsapp"), bot:($f.name+"-bot"), scheduler:($f.name+"-scheduler")} |
  .parameters.mail.SesFrom = $f.ses_from |
  .parameters.gmail.GmailOAuthSecretArn = $f.gmail_secret_arn |
  .parameters.whatsapp += {VpcId:$f.vpc_id, SubnetId:$f.subnet_id, AmiId:$f.ami_id,
    KeyName:$f.key_name, AllowedSshIpv6Cidr:$f.ssh_ipv6_cidr,
    IntegrationSecurityGroupId:$f.integration_security_group_id} |
  .parameters.bot += {VpcId:$f.vpc_id, SubnetId:$f.subnet_id, AmiId:$f.ami_id,
    KeyName:$f.key_name, AllowedSshIpv6Cidr:$f.ssh_ipv6_cidr,
    IntegrationSecurityGroupId:$f.integration_security_group_id,
    ApplicationSecretArn:$f.application_secret_arn, DynamoDbTableName:$f.bets_table,
    UseLambdaVpcEndpoint:"false", ConfirmPayment:"false"} |
  .parameters.scheduler += {VpcId:$f.vpc_id, SubnetIds:$f.subnet_id,
    RouteTableIds:$f.route_table_id, LambdaEndpointSecurityGroupId:$f.lambda_endpoint_sg_id,
    DynamoDbTableName:$f.executions_table, MailTo:$to, CreateDynamoGateway:"false",
    RunBetState:"DISABLED", CheckDrawsState:"DISABLED"} |
  .scheduler_paused = true
' examples/terraform.tfvars.json > "$config"
jq -e '[.. | strings | select(contains("SUBSTITUA"))] | length == 0' "$config" >/dev/null
# Link sem sobrescrita: uma configuração existente nunca é substituída.
ln "$config" terraform.tfvars.json
(set -o noclobber; printf '{"scheduler_paused":true}\n' > maintenance.auto.tfvars.json)
echo 'Configuração criada. Preencha/verifique os secrets e SES antes de preparar e aplicar as aplicações.'
