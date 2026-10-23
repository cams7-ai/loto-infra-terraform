#!/usr/bin/env bash
# Diagnóstico somente de leitura; não inicia sessões nem apostas.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SSH_KEY:?Caminho da chave privada}"
for tool in terraform aws jq ssh; do command -v "$tool" >/dev/null; done
mkdir -p .local
out=$(terraform output -json stack_outputs)
wa_id=$(jq -r '.whatsapp.InstanceId' <<< "$out")
bot_id=$(jq -r '.bot.InstanceId' <<< "$out")
wa_url=$(jq -r '.whatsapp.ApiUrl' <<< "$out")
[[ "$wa_url" =~ ^http://[a-zA-Z0-9.-]+$ ]] || { echo 'URL inesperada' >&2; exit 1; }
ip6() {
  aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' --output text
}
opts=(-6 -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$PWD/.local/known_hosts")
ssh "${opts[@]}" "ubuntu@$(ip6 "$wa_id")" 'set -e; sudo systemctl is-active whatsapp-notify nginx; sudo nginx -t; curl -fsS --max-time 20 http://127.0.0.1:8000/whatsapp/session/status; curl -fsS --max-time 20 http://127.0.0.1/whatsapp/session/status'
ssh "${opts[@]}" "ubuntu@$(ip6 "$bot_id")" "set -e; sudo systemctl is-active loto-bot nginx; sudo nginx -t; curl -fsS --max-time 20 http://127.0.0.1:8000/health; curl -fsS --max-time 20 http://127.0.0.1/health; curl -fsS --max-time 20 '$wa_url/whatsapp/session/status'"
echo 'APIs e proxy responderam. Sessão WhatsApp fechada não equivale a falha HTTP.'

bash scripts/check-scheduler.sh
