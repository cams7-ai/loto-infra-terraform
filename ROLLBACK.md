# ROLLBACK — desmontagem completa do ambiente AWS

Este roteiro desfaz a implantação das cinco aplicações e da infraestrutura criada por `foundation/`. É uma **desmontagem definitiva**, incluindo dados, volumes EC2, artefatos e credenciais armazenadas. Para retornar apenas à versão anterior das aplicações, use a reversão de versão em [OPERACAO.md](OPERACAO.md).

Execute na raiz deste projeto, em Bash, um bloco por vez. Revise cada plano antes do respectivo `apply`. Criar este documento não executa nenhuma exclusão. A ordem é: pausar jobs, preservar o necessário, excluir scheduler, excluir as outras aplicações, excluir fundação e conferir recursos restantes.

## 1. Confirmar conta, região, states e escopo

Use as variáveis do ambiente que foi implantado; não copie nomes de stacks de outro ambiente. Preserve `terraform.tfvars.json`, `releases.auto.tfvars.json`, `prepared/`, a chave SSH e os arquivos de backend até finalizar. O Terraform precisa dos templates mesmo para planejar a remoção das stacks.

```bash
: "${AWS_PROFILE:?Exporte o perfil do ambiente}"
: "${AWS_REGION:?Exporte a região do ambiente}"
: "${EXPECTED_ACCOUNT_ID:?Exporte o ID da conta do ambiente}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=''
(
  set -euo pipefail
  actual_account=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
  [[ "$actual_account" == "$EXPECTED_ACCOUNT_ID" ]]
  jq -e --arg account "$EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" \
    '.account_id == $account and .region == $region' terraform.tfvars.json >/dev/null
)
terraform workspace show
terraform state list
terraform -chdir=foundation workspace show
terraform -chdir=foundation state list
```

Continue somente se o bloco de conferência terminar com sucesso e os workspaces/states forem os do ambiente correto. Os dois states são independentes. `No state file was found` não comprova que a AWS esteja vazia: confira backend, workspace e recursos reais antes de prosseguir. Não execute `configure-new.sh`, `adopt.sh` nem `prepare.sh` para preparar uma exclusão.

O fluxo completo abaixo pressupõe as cinco stacks implantadas e a fundação gerenciada por este projeto. Em uma implantação parcial, execute somente as etapas dos recursos presentes no state, sem criar recursos faltantes. Se o scheduler nunca existiu, pule sua pausa/exclusão. Se as aplicações nunca foram implantadas, prossiga diretamente à fundação após confirmar isso na AWS. Para infraestrutura externa/adotada, a etapa 7 delimita o que deve ser tratado separadamente.

**Backend remoto:** se um bucket ou tabela a excluir também guarda state/locks, migre antes os dois states para armazenamento fora do ambiente. Altere o bloco de backend para `backend "local" {}` em cada diretório afetado, execute `terraform init -migrate-state` na raiz e `terraform -chdir=foundation init -migrate-state` na fundação, confira a migração e faça backup. Não use `-reconfigure` para substituir a migração. Se o backend é compartilhado, preserve o bucket e exclua apenas os objetos/versões e locks exclusivos deste ambiente, depois da conclusão. Consulte [backends em OPERACAO.md](OPERACAO.md#state).

## 2. Registrar inventário e fazer backup

Crie um diretório protegido antes de alterar as configurações:

```bash
umask 077
ROLLBACK_DIR="$PWD/.local/rollback-$(date '+%Y%m%d-%H%M%S')"
export ROLLBACK_DIR
mkdir -p "$ROLLBACK_DIR"
terraform state pull > "$ROLLBACK_DIR/applications.tfstate.json"
terraform -chdir=foundation state pull > "$ROLLBACK_DIR/foundation.tfstate.json"
terraform output -json stack_outputs > "$ROLLBACK_DIR/stack-outputs.json"
terraform -chdir=foundation output -json configuration > "$ROLLBACK_DIR/foundation.json"
cp main.tf "$ROLLBACK_DIR/applications-main.tf.original"
cp foundation/main.tf "$ROLLBACK_DIR/foundation-main.tf.original"
cp terraform.tfvars.json "$ROLLBACK_DIR/applications.tfvars.json"
cp foundation/terraform.tfvars.json "$ROLLBACK_DIR/foundation.tfvars.json"
cp -a prepared "$ROLLBACK_DIR/prepared"
for config in releases.auto.tfvars.json maintenance.auto.tfvars.json backend.hcl foundation/backend.hcl; do
  if [[ -f "$config" ]]; then
    cp "$config" "$ROLLBACK_DIR/${config//\//-}"
  fi
done
```

Omita somente os comandos de módulos/arquivos que nunca existiram, conforme a conferência da etapa 1. Guarde também a configuração dos backends e os arquivos `.terraform.lock.hcl`. Não publique o conteúdo de `.terraform/`, que pode conter configuração de autenticação.

Para cada stack existente, salve o ARN, os recursos físicos e a proteção de terminação; o inventário permite identificar recursos retidos depois da exclusão:

```bash
(
  set -euo pipefail
  for key in scheduler bot whatsapp gmail mail; do
    stack=$(jq -er --arg key "$key" '.stack_names[$key]' terraform.tfvars.json)
    aws cloudformation describe-stacks --stack-name "$stack" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" > "$ROLLBACK_DIR/$key-stack.json"
    aws cloudformation list-stack-resources --stack-name "$stack" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" > "$ROLLBACK_DIR/$key-resources.json"
  done
)
```

Antes de excluir dados, decida o que será preservado fora dos recursos a remover:

- EC2: `/opt/loto-bot/data`, `/opt/whatsapp-notify/data`, arquivos `/etc/*.env` das aplicações, perfis autenticados e logs necessários. Pare os processos antes da cópia final para obter arquivos consistentes.
- DynamoDB: histórico de apostas e execuções/locks. Para recuperação, faça backup sob demanda/exportação e confira sua disponibilidade; uma cópia do state não contém os itens das tabelas.
- Scheduler: mensagens pendentes nas filas de falha/DLQ e logs necessários para reconciliação.
- S3: releases e versões que precisem ser preservadas. Uma sincronização dos objetos atuais não preserva automaticamente todas as versões.
- Secrets: se houver necessidade de recuperação, guarde os valores em armazenamento protegido; o state da fundação administra os contêineres e não substitui o backup dos valores publicados pela CLI.

Proteja backups com criptografia, acesso restrito e transporte seguro. Coloque as cópias fora do bucket/VPC/volumes que serão eliminados. Snapshots, backups e exportações mantidos na AWS são recursos remanescentes e podem continuar gerando cobrança.

## 3. Pausar e encerrar atividades

Pause o scheduler enquanto as proteções de exclusão ainda estão ativas:

```bash
printf '{"scheduler_paused":true}\n' > maintenance.auto.tfvars.json
terraform plan -out=.local/rollback-pause.tfplan
terraform show .local/rollback-pause.tfplan
```

O plano deve conter somente a pausa esperada; se houver outras diferenças, resolva-as antes do apply.

```bash
terraform apply .local/rollback-pause.tfplan
bash scripts/check-scheduler.sh
```

Confira os dois schedules em `DISABLED`. Pare schedulers locais/externos e aguarde invocações, sessões e operações de pagamento em andamento terminarem. Desabilitar schedules não cancela execuções já entregues; não apague locks para forçar a desmontagem. Reconcilie operações pendentes antes de excluir o histórico.

Encerre as sessões pelas APIs, como em [EXECUCAO.md](EXECUCAO.md), e depois pare `loto-bot` e `whatsapp-notify` nas respectivas EC2 para concluir os backups. Encerre somente o túnel deste ambiente. Para o serviço local documentado:

```bash
systemctl --user disable --now loto-socks.service
```

Se usou um túnel temporário com socket de controle, use o `ssh -S ... -O exit` correspondente, conforme EXECUCAO.md. Não encerre processos SSH de outros ambientes.

## 4. Excluir primeiro o scheduler

Em `main.tf`, altere para `false` o `prevent_destroy` **somente** no recurso `aws_cloudformation_stack.scheduler`. Mantenha o recurso e seus parâmetros no arquivo. Essa alteração local é intencional para a desmontagem; não remove a stack sozinha. [Como funciona prevent_destroy](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#prevent_destroy).

Se `EnableTerminationProtection` estiver ativo no inventário da stack, desative a proteção de terminação dessa stack antes de aplicar a exclusão:

```bash
SCHEDULER_STACK=$(jq -er '.stack_names.scheduler' terraform.tfvars.json)
# Execute somente se a proteção de terminação estiver ativa:
aws cloudformation update-termination-protection --no-enable-termination-protection \
  --stack-name "$SCHEDULER_STACK" --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

Planeje a exclusão isolada:

```bash
terraform plan -destroy -target=aws_cloudformation_stack.scheduler -out=.local/remove-scheduler.tfplan
terraform show .local/remove-scheduler.tfplan
```

Confirme que o plano exclui apenas o scheduler. `-target` é usado aqui exclusivamente para desmontar em etapas.

```bash
terraform apply .local/remove-scheduler.tfplan
```

Aguarde a exclusão completa e a liberação das interfaces de rede da Lambda antes de remover a fundação. O scheduler inclui os schedules, Lambda, filas SQS, log group, permissões e regras/SGs definidos no template implantado. A tabela de execuções é externa à stack e permanece até a etapa 6. Se `CreateDynamoGateway=true`, confira o endpoint e as rotas que a stack excluirá.

## 5. Excluir bot, WhatsApp, Gmail e mail

Em `main.tf`, altere também para `false` o `prevent_destroy` das quatro stacks restantes. Se alguma tiver proteção de terminação CloudFormation, desative-a para o nome exato registrado no inventário, usando o comando da etapa 4. Não remova os blocos de recursos nem execute um apply normal na raiz a partir daqui: ele poderia recriar o scheduler já removido.

```bash
terraform plan -destroy -out=.local/remove-applications.tfplan
terraform show .local/remove-applications.tfplan
```

Confira os nomes reais e a exclusão das quatro stacks, sem criações. As referências do Terraform determinam a remoção do bot antes de mail/Gmail/WhatsApp.

```bash
terraform apply .local/remove-applications.tfplan
terraform state list
```

O state da raiz não deve conter recursos gerenciados. Confirme também a exclusão das stacks na AWS. As EC2 são terminadas; os volumes raiz dos templates atuais têm `DeleteOnTermination=true`, portanto os dados locais serão perdidos. Recursos com `DeletionPolicy: Retain`, snapshots ou recursos externos não são apagados automaticamente. Confira o template efetivamente implantado, especialmente nas stacks adotadas.

Se ocorrer `DELETE_FAILED`, consulte os eventos da stack pelo ARN salvo e corrija a causa antes de gerar um novo plano de destruição. Não use `terraform state rm` para fingir que a exclusão terminou. Dependências externas, proteção de terminação e ENIs ainda em uso devem ser resolvidas sem excluir recursos de terceiros. Consulte o [diagnóstico CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/troubleshooting.html).

## 6. Excluir a fundação gerenciada por Terraform

Execute esta etapa somente após remover as aplicações e confirmar que nenhum outro ambiente depende da VPC, bucket, tabelas, secrets ou identidade SES. Confira os recursos em `foundation/` contra o inventário da etapa 2. Não exclua manualmente pela CLI recursos ainda gerenciados por esse state.

### 6.1. Preparar as proteções antes do destroy

Edite `foundation/main.tf` apenas para esta desmontagem:

| Recurso | Alteração temporária |
|---|---|
| Todos os recursos com `lifecycle { prevent_destroy = true }` | Trocar o valor para `false`, preservando os recursos |
| `aws_dynamodb_table.bets` e `.executions` | `deletion_protection_enabled = false` |
| `aws_s3_bucket.artifacts` | `force_destroy = true` |
| `aws_secretsmanager_secret.application` e `.gmail` | Manter `recovery_window_in_days = 30`, ou usar `0` se a decisão for eliminar sem recuperação |

**Antes de executar os comandos Terraform abaixo, abra o arquivo e salve as alterações da tabela:**

```bash
"${EDITOR:-nano}" foundation/main.tf
```

Troque `prevent_destroy = true` por `false` nos sete recursos: `aws_vpc.main`, `aws_s3_bucket.artifacts`, `aws_key_pair.ssh`, `aws_secretsmanager_secret.application`, `aws_secretsmanager_secret.gmail`, `aws_dynamodb_table.bets` e `aws_dynamodb_table.executions`. Preserve os blocos de recursos. Nas duas tabelas, altere também `deletion_protection_enabled` para `false`; no bucket, altere `force_destroy` para `true`. As proteções em `main.tf` da raiz são independentes: alterá-las não libera os recursos de `foundation/main.tf`.

Confira os valores salvos:

```bash
rg -n 'prevent_destroy|deletion_protection_enabled|force_destroy' foundation/main.tf
```

O resultado deve mostrar sete `prevent_destroy = false`, dois `deletion_protection_enabled = false` e um `force_destroy = true`. **Não prossiga se algum valor divergir.** `terraform fmt -check` verifica apenas a formatação; não faz essas alterações nem confirma que as proteções foram liberadas. Enquanto houver `prevent_destroy = true`, o plano de exclusão será rejeitado com `Error: Instance cannot be destroyed`.

O bucket é versionado: `aws s3 rm --recursive` não remove todas as versões e marcadores de exclusão. `force_destroy=true` autoriza o provider a apagar seu conteúdo na destruição. **É obrigatório aplicar essa configuração ao state antes do plano de destroy.** A proteção DynamoDB também deve ser desabilitada na AWS antes da exclusão. Veja a [referência do provider S3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) e o [esvaziamento de buckets versionados](https://docs.aws.amazon.com/AmazonS3/latest/userguide/empty-bucket.html).

Com janela de 30 dias, os secrets ficam inacessíveis e agendados para exclusão; continuam recuperáveis nesse prazo. Com `0`, a remoção não tem recuperação e o processamento pode ser assíncrono. Escolha antes do apply de preparação; não execute `delete-secret` por fora do Terraform. [Exclusão de secrets](https://docs.aws.amazon.com/secretsmanager/latest/userguide/manage_delete-secret.html), [parâmetro recovery_window_in_days](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret).

**Execute o bloco inteiro abaixo.** A verificação inicial interrompe o bloco se as alterações não estiverem salvas, evitando repetir `No changes` na preparação e `Instance cannot be destroyed` no plano de exclusão. Se ela falhar, volte ao editor e corrija os valores antes de repetir o bloco.

```bash
(
set -e
if [[ "$(rg -c 'prevent_destroy[[:space:]]*=[[:space:]]*false' foundation/main.tf)" != 7 ]] ||
   [[ "$(rg -c 'deletion_protection_enabled[[:space:]]*=[[:space:]]*false' foundation/main.tf)" != 2 ]] ||
   [[ "$(rg -c 'force_destroy[[:space:]]*=[[:space:]]*true' foundation/main.tf)" != 1 ]] ||
   rg -q '(prevent_destroy|deletion_protection_enabled)[[:space:]]*=[[:space:]]*true|force_destroy[[:space:]]*=[[:space:]]*false' foundation/main.tf; then
  printf '%s\n' 'PARE: salve as alterações da etapa 6.1 em foundation/main.tf antes de continuar.' >&2
  exit 1
fi
terraform -chdir=foundation fmt -check
terraform -chdir=foundation plan -out=../.local/prepare-foundation-removal.tfplan
terraform -chdir=foundation show ../.local/prepare-foundation-removal.tfplan
)
```

Este é um plano normal de **preparação**, não de exclusão. Deve apenas atualizar as opções descritas; não deve criar ou substituir recursos. Se recursos já foram removidos numa tentativa anterior, não aplique um plano que os recrie: reconcilie o state e prepare somente as opções dos recursos restantes antes de continuar.

Se as tabelas ainda estiverem protegidas e o bucket ainda tiver `force_destroy = false`, o plano deve mostrar essas mudanças. Um plano que altera somente o output `ami_id` não prepara esses recursos para exclusão: volte à edição de `foundation/main.tf` e gere novamente o plano. A mudança de `prevent_destroy` é conferida no arquivo e não aparece como atualização de infraestrutura no plano.

```bash
terraform -chdir=foundation apply ../.local/prepare-foundation-removal.tfplan
```

### 6.2. Planejar e aplicar a destruição

Só prossiga após a verificação e o apply da etapa 6.1 concluírem com sucesso. No cenário do log com as proteções ainda habilitadas, `No changes` seguido de `Resources: 0 added, 0 changed, 0 destroyed` significa que a preparação não foi feita; repetir o plano de destruição produzirá o mesmo erro. Após corrigir e aplicar a preparação, gere um novo plano de exclusão.

```bash
terraform -chdir=foundation plan -destroy -out=../.local/remove-foundation.tfplan
terraform -chdir=foundation show ../.local/remove-foundation.tfplan
```

Revise a exclusão de VPC, subnet, internet gateway, rotas, endpoints, SGs, bucket e seu conteúdo, chave pública EC2, tabelas e secrets, além da identidade SES do remetente. A chave SSH privada local não é apagada pelo Terraform.

```bash
terraform -chdir=foundation apply ../.local/remove-foundation.tfplan
terraform -chdir=foundation state list
```

Não devem restar recursos gerenciados nesse state. Se houver erro, preserve o state atualizado, corrija a causa e gere um novo plano `-destroy`; não reutilize um plano antigo nem restaure o state anterior. `BucketNotEmpty` exige conferir versões/marcadores, uploads multipart pendentes e se `force_destroy` foi aplicado. Dependências de ENIs exigem aguardar a liberação ou identificar o serviço que ainda as utiliza; não apague ENIs gerenciadas por serviços indiscriminadamente.

## 7. Tratar recursos externos e remanescentes

State vazio comprova apenas a remoção dos recursos que o Terraform administrava. Use os IDs/ARNs salvos para conferir cada recurso na mesma conta/região. Erros de acesso ou credenciais não são prova de exclusão.

| Item | Conferência e ação |
|---|---|
| Stacks | Conferir exclusão pelo ARN salvo; identificar qualquer recurso retido no inventário |
| Lambda, schedules/grupo, SQS e CloudWatch Logs | Conferir os nomes/IDs dos templates implantados; remover apenas recursos exclusivos que tenham ficado fora da exclusão das stacks |
| EC2, EBS, snapshots, ENIs e SGs | Conferir instâncias terminadas e volumes/recursos retidos; snapshots/AMIs criados para backup exigem tratamento separado |
| Bucket de artefatos | Conferir remoção do bucket, versões/marcadores e uploads multipart; não apagar o backend antes de concluir/migrar os states |
| DynamoDB | Conferir as duas tabelas ausentes; inventariar backups sob demanda, backups de sistema, exportações S3 e recovery points no AWS Backup; apagar somente cópias exclusivas cuja perda foi decidida, respeitando retenções/bloqueios do serviço |
| Secrets Manager | Conferir ausência ou `DeletedDate`, conforme a janela escolhida; acompanhar até o fim da exclusão e verificar réplicas se foram adicionadas fora do projeto |
| SES | A identidade `ses_from` gerenciada pela fundação é removida; destinatários verificados manualmente, como `SCHEDULER_MAIL_TO`, permanecem |
| Fundação externa ou recursos adotados | VPC, endpoints, tabelas, secrets e bucket externos não pertencem ao state `foundation/`; inventariar dependências e remover pelo proprietário original somente quando exclusivos deste ambiente |
| Backend remoto | Após encerrar as operações, tratar as versões dos dois states e locks exclusivos; manter buckets compartilhados |
| Outros recursos adicionados manualmente | Conferir alarmes, logs extras, backups, NAT/EIP, endpoints e recursos em outras regiões; não excluir por prefixo sem verificar propriedade |

Para conferir backups DynamoDB usando os nomes registrados antes da exclusão:

```bash
for field in bets_table executions_table; do
  table=$(jq -er --arg field "$field" '.[$field]' "$ROLLBACK_DIR/foundation.json")
  aws dynamodb list-backups --table-name "$table" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION"
done
```

Se uma identidade SES de destinatário foi criada manualmente **somente para este ambiente**, confirme que nenhum outro sistema a usa e remova pelo endereço exato:

```bash
: "${SCHEDULER_MAIL_TO:?Informe o destinatário exclusivo a remover}"
aws sesv2 delete-email-identity --email-identity "$SCHEDULER_MAIL_TO" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

Não remova uma identidade compartilhada. Excluir o secret OAuth da AWS não revoga o acesso na conta Google: revogue separadamente a autorização do aplicativo se não será mais usada. Para o WhatsApp, desconecte o dispositivo deste ambiente em **Aparelhos conectados** no celular. Essas autorizações externas não são recursos Terraform.

## 8. Encerrar e restaurar as proteções locais

Depois de confirmar a remoção, guarde os states finais e o inventário junto ao backup protegido. Restaure **somente** as alterações temporárias de desmontagem em `main.tf` e `foundation/main.tf`: `prevent_destroy=true`, `force_destroy=false`, proteção das tabelas habilitada e janela dos secrets em 30 dias. Compare com as cópias `.original` da etapa 2; preserve alterações legítimas que tenham sido feitas em paralelo. Não restaure os states antigos e não execute um apply normal, pois isso recriaria o ambiente.

Desabilite/remova o serviço local de túnel exclusivo e seus sockets; trate chaves privadas, QR codes, configurações, planos e backups conforme sua decisão de retenção. Não apague a chave privada enquanto ainda precisar de acesso às EC2. Dados mantidos em backups continuam existindo, mesmo após a exclusão dos serviços.

A desmontagem está concluída quando os dois states não têm recursos gerenciados, os recursos exclusivos inventariados foram removidos e quaisquer retenções pendentes estão registradas com prazo/responsável. Revise também a cobrança após a atualização dos dados de uso: custos já incorridos não são cancelados pelo destroy, e backups/recursos preservados podem continuar cobrando.
