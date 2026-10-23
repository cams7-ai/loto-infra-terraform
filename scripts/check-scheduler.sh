#!/usr/bin/env bash
# Inspeção somente de leitura; não invoca a Lambda nem inicia jobs.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in terraform aws jq; do command -v "$tool" >/dev/null; done
out=$(terraform output -json stack_outputs)
function_name=$(jq -er '.scheduler.FunctionName' <<< "$out")
group=$(jq -er '.scheduler.ScheduleGroupName' <<< "$out")
table=$(jq -er '.scheduler.TableName' <<< "$out")
aws lambda get-function-configuration --function-name "$function_name" --query '{State:State,LastUpdateStatus:LastUpdateStatus}' --output json |
  jq -e '.State == "Active" and .LastUpdateStatus == "Successful"' >/dev/null
aws dynamodb describe-table --table-name "$table" --query Table.TableStatus --output json |
  jq -e '. == "ACTIVE"' >/dev/null
expected=$(terraform output -json scheduler_states)
for pair in RunBetScheduleName:RunBetState CheckDrawsScheduleName:CheckDrawsState; do
  output_key=${pair%%:*}; state_key=${pair#*:}
  name=$(jq -er --arg key "$output_key" '.scheduler[$key]' <<< "$out")
  state=$(jq -er --arg key "$state_key" '.[$key]' <<< "$expected")
  aws scheduler get-schedule --group-name "$group" --name "$name" --query '{State:State,Timezone:ScheduleExpressionTimezone}' --output json |
    jq -e --arg state "$state" '.State == $state and .Timezone == "America/Sao_Paulo"' >/dev/null
  printf '%s: %s\n' "$output_key" "$state"
done
echo 'Scheduler: Lambda ativa, tabela disponível e estados conferidos; nenhum job foi invocado.'
