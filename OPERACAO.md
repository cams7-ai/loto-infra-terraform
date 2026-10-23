# Operação, reversão e limites

## State

Os backends iniciais da raiz e de `foundation/` são locais, com locks próprios. Faça backup dos dois states, das configurações e da chave SSH. Só um operador/cópia deve administrar este ambiente. Proteja e faça backup do state; restaurar um state antigo não reverte a infraestrutura.

Para S3 remoto, crie antes um bucket privado, criptografado e com versionamento. Adicione um arquivo `backend.tf` contendo:

```hcl
terraform {
  backend "s3" {}
}
```

Copie `examples/backend.hcl`, preencha seus valores e execute:

```bash
terraform init -migrate-state -backend-config=backend.hcl
```

Para a fundação, configure o backend em `foundation/` e use uma `key` S3 diferente da raiz; execute a migração com `terraform -chdir=foundation init -migrate-state` e seu arquivo de backend correspondente. Nunca aponte ambos para a mesma chave de state. Revise a migração apresentada. O lock S3 usa `use_lockfile=true`; não precisa de tabela DynamoDB para lock. Referência: [backend S3](https://developer.hashicorp.com/terraform/language/backend/s3).

## Reversão das stacks

Restaure os templates `prepared/`, parâmetros e `releases.auto.tfvars.json` da versão anterior, mantendo os objetos S3 correspondentes. Se a versão anterior não tinha releases.auto.tfvars.json, mova o arquivo atual para o backup, para não sobrescrever os parâmetros anteriores.

Pause primeiro os agendamentos e aguarde a conclusão das invocações/sessões conforme a etapa 4 de EXECUCAO.md. Mantenha `maintenance.auto.tfvars.json` com `scheduler_paused=true` durante a reversão; não restaure um arquivo de manutenção antigo que libere jobs antes da validação.

Restaure também `prepared/loto-scheduler-aws.yaml` e `parameters.scheduler` da versão desejada, preservando o nome da stack e a tabela de execuções atual. Não restaure um backup anterior à integração que omita o scheduler na configuração; complete-o antes de planejar.

Execute `terraform plan -out=.local/rollback.tfplan`, revise e aplique. Isso reverte configuração e pacotes Lambda, quando suportado pelo CloudFormation. Não restaura dados, perfis, banco ou volumes eliminados. O Terraform recalcula URL/SG do bot e ARN do mail-sender para o scheduler após mudanças das dependências. Se necessário, reverta também o código EC2 pelo procedimento abaixo, valide túnel/APIs e execute `bash scripts/check.sh`. Só depois libere os estados configurados dos schedules com a etapa 9 de EXECUCAO.md. Preserve histórico, deduplicação e `REMOTE_GUARD` da tabela; recuperação de locks requer o procedimento do repositório do scheduler.

## Reversão do código EC2

O Ansible guarda a instalação original em `/opt/APP/bootstrap-original` e versões posteriores em `/opt/APP/releases/SHA256`. Perfis continuam em `/opt/APP/data`.

Para uma reversão manual, na EC2 correta:

```bash
APP=whatsapp-notify
PREVIOUS=$(sudo cat "/opt/$APP/previous-release")
sudo test -x "$PREVIOUS/.venv/bin/$APP"
sudo systemctl stop "$APP"
sudo ln -sfn "$PREVIOUS" "/opt/$APP/app"
sudo systemctl start "$APP"
sudo nginx -t && sudo systemctl reload nginx
```

Para o bot, altere APP para loto-bot. Rode novamente `check.sh`. Essa reversão não corrige migrações de dados nem mudanças incompatíveis de configuração.

## Configuração nas EC2

O playbook atual é específico para atualização de código em instâncias inicializadas pelo template. Não altera os arquivos `/etc/loto-bot.env` e `/etc/whatsapp-notify.env`, usuários, serviço systemd ou configuração Nginx em disco. Ele valida e recarrega a configuração já instalada.

Se mudar `ConfirmPayment`, secret ARN, URLs, tabela, variáveis ou configuração Nginx, alinhe também a configuração no host. Para alteração simples, edite o arquivo correto via `sudoedit`, preserve root:root/0600 nos arquivos .env, valide o Nginx quando aplicável e reinicie o serviço. Não registre valores secretos no terminal ou no Git.

Mudanças amplas de bootstrap devem usar uma substituição EC2 planejada, com backup de dados e restauração. Atualização de UserData por CloudFormation pode parar/iniciar a instância e não reexecuta automaticamente o bootstrap. Não execute cloud-init indiscriminadamente sobre uma instância em operação.

## Remoção

Para desmontar definitivamente as aplicações e a fundação, siga [ROLLBACK.md](ROLLBACK.md). O roteiro inclui pausa dos jobs, backups, exclusão do scheduler antes das demais stacks, preparação das proteções DynamoDB/S3/secrets, destruição da fundação e conferência dos recursos restantes.

A desmontagem exclui dados e é diferente da reversão de versão descrita acima. `prevent_destroy` bloqueia a exclusão pelo Terraform enquanto estiver ativo na configuração; não protege contra exclusão pelo console nem contra substituições internas do CloudFormation. Preserve os dois states e não execute `delete-stack` em paralelo para stacks administradas pelo Terraform.

## Diagnóstico

| Sintoma | Verificação |
|---|---|
| 8000 responde e 80 retorna 404 | `sudo nginx -t`, sites-enabled, `sudo systemctl reload nginx` |
| localhost funciona e bot não alcança WhatsApp | DNS privado, SG de integração e regra HTTP |
| SSH IPv6 falha | IPv6 local, CIDR /128, chave, estado EC2 e rotas |
| API saudável, browser sem rede | serviço local do túnel, socket 1080 e teste SOCKS |
| Stack concluiu, código não mudou | executar playbook; UserData não é atualização contínua |
| Build Lambda falha | Docker, dependências do requirements e logs SAM |

Referências: [stacks no provider AWS](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudformation_stack), [importação Terraform](https://developer.hashicorp.com/terraform/language/import).

## Alterações na fundação

Revise planos em `foundation/` separadamente. Após uma alteração de IDs/ARNs, compare `terraform -chdir=foundation output -json configuration` com `terraform.tfvars.json` e alinhe os parâmetros das aplicações antes de um novo deploy. `configure-new.sh` é exclusivo da instalação inicial. O endpoint Lambda da instalação nova pertence à fundação; mantenha `UseLambdaVpcEndpoint=false` no bot e `CreateDynamoGateway=false` no scheduler. Valores dos secrets são publicados fora do Terraform; a fundação não mantém suas versões no state.
