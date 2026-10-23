#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
: "${SSH_KEY:?Exporte caminho absoluto da chave privada}"
mkdir -p .local
outputs=$(terraform output -json stack_outputs)
printf '{"all":{"hosts":{}}}\n' > .local/inventory.json
for pair in whatsapp:whatsapp-notify bot:loto-bot; do
  key=${pair%%:*}; app=${pair#*:}
  id=$(jq -r --arg k "$key" '.[$k].InstanceId' <<< "$outputs")
  ip=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' --output text)
  [[ "$ip" == *:* ]]
  sha=$(jq -r --arg k "$key" '.artifact_parameters[$k].ArtifactSha256' releases.auto.tfvars.json)
  object=$(jq -r --arg k "$key" '.artifact_parameters[$k].ArtifactKey' releases.auto.tfvars.json)
  base=${object##*/}; revision=${base%%-*}
  zip="$PWD/dist/$app-$revision.zip"
  [[ $(sha256sum "$zip" | cut -d' ' -f1) == "$sha" ]]
  health=/health
  [[ "$key" != whatsapp ]] || health=/whatsapp/session/status
  jq --arg app "$app" --arg ip "$ip" --arg ssh "$SSH_KEY" --arg sha "$sha" --arg zip "$zip" --arg health "$health" --arg opts "-6 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$PWD/.local/known_hosts" '.all.hosts[$app]={ansible_host:$ip,ansible_user:"ubuntu",ansible_ssh_private_key_file:$ssh,ansible_ssh_common_args:$opts,app_name:$app,release_sha:$sha,release_zip:$zip,health_path:$health}' .local/inventory.json > .local/i.tmp
  mv .local/i.tmp .local/inventory.json
done
ansible-inventory -i .local/inventory.json --list >/dev/null
echo 'Inventário gerado em .local/inventory.json'
