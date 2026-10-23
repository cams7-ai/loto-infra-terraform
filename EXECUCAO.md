# Passo a passo de execução

Este roteiro começa com uma conta AWS sem a infraestrutura do LotoBot. A fundação é criada primeiro; depois são criadas as cinco stacks. Para instalações já existentes, use somente o caminho alternativo de adoção da etapa 3.

Para desfazer a implantação completa, incluindo a fundação, siga [ROLLBACK.md](ROLLBACK.md). Para retornar a uma versão anterior, consulte [OPERACAO.md](OPERACAO.md).

## 1. Posicionar o projeto

Mantenha o projeto em um diretório de sua escolha, junto aos repositórios das aplicações e do scheduler. Nos exemplos abaixo, `$HOME/projetos` representa esse diretório base. Ajuste os valores ao seu ambiente antes de executar os comandos. Não execute duas cópias com states independentes.

Os cinco repositórios abaixo precisam ser baixados na máquina local. Para cloná-los com Git:

```bash
mkdir -p "$HOME/projetos"
cd "$HOME/projetos"
git clone https://github.com/cams7-ai/mail-sender-aws.git
git clone https://github.com/cams7-ai/gmail-reader-aws.git
git clone https://github.com/cams7-ai/whatsapp-notify.git
git clone https://github.com/cams7-ai/loto-bot.git
git clone https://github.com/cams7-ai/loto-scheduler-aws.git
```

Se algum repositório já estiver presente, reutilize a cópia local e confira a versão antes de prosseguir. O Terraform deste projeto administra as cinco stacks, incluindo o `loto-scheduler-aws`. SAM prepara seus artefatos; o deploy e o rollback das stacks são feitos por este projeto. Não execute `scripts/deploy.py` ou `sam deploy` em paralelo ao Terraform.

Com os repositórios disponíveis localmente, configure o ambiente de execução:

```bash
cd "$HOME/projetos/loto-infra-terraform"
umask 077
export AWS_PROFILE=<perfil-exemplo>
export AWS_REGION=<regiao-aws>
export EXPECTED_ACCOUNT_ID=<substitua-pelo-id-de-12-digitos>
export SOURCE_ROOT="$HOME/projetos"
export SSH_KEY="$PWD/.local/loto-ssh"
export SES_FROM=<seu-email-verificado@example.com>
export SCHEDULER_MAIL_TO=<destinatario-configurado@example.com>
aws sts get-caller-identity --profile $AWS_PROFILE
```

Substitua o perfil, a região, o ID da conta, os e-mails e os caminhos pelos valores do ambiente de destino. `AWS_PROFILE` deve corresponder a um perfil configurado na AWS CLI; `SOURCE_ROOT` deve apontar para o diretório que contém os cinco repositórios clonados. Não exporte senhas, tokens ou dados de cartão. O bucket e a chave SSH serão criados na próxima etapa; `ARTIFACT_BUCKET` será preenchido com o nome retornado pelo Terraform.

## 2. Criar a infraestrutura básica

Siga [FUNDACAO.md](FUNDACAO.md) integralmente antes de preparar as aplicações. O documento fornece comandos para:

- gerar uma chave SSH local e cadastrar somente sua chave pública;
- criar VPC/subnet dual-stack, rota IPv6, Security Groups e endpoints;
- criar o bucket privado de artefatos, as duas tabelas DynamoDB e os contêineres dos secrets;
- cadastrar o remetente SES, confirmar sua verificação e gravar os valores dos secrets fora do Terraform;
- exportar o bucket e gerar `terraform.tfvars.json` com os IDs/ARNs reais.

A fundação tem configuração/state próprios em `foundation/`. Não depende dos templates em `prepared/`, de um bucket prévio ou de stacks implantadas. Os endpoints de interface geram cobrança enquanto existirem; revise o plano antes de aplicar.

## 3. Configurar as stacks novas

Depois de concluir FUNDACAO.md, o script `bash scripts/configure-new.sh` já terá gerado a configuração das cinco aplicações com base na fundação. Ele recusa sobrescrever configurações existentes. Revise `terraform.tfvars.json`, inclusive e-mails, tipos de instância e parâmetros do Gmail/scheduler. `ConfirmPayment=false`, os dois schedules `DISABLED` e `scheduler_paused=true` devem permanecer na primeira implantação.

Execute na raiz deste projeto:

```bash
terraform init
```

**Não execute `adopt.sh` em uma instalação nova.** Prossiga diretamente para a etapa 5. O arquivo de pausa já foi criado por `configure-new.sh`; a etapa 4 é para futuras atualizações.

### Caminho alternativo: adotar uma instalação existente

Se você já possui a fundação e as cinco stacks implantadas, não crie a fundação novamente e não execute `configure-new.sh`. Defina `ARTIFACT_BUCKET` com o bucket privado existente, `SSH_KEY` com a chave privada correspondente às EC2 e os e-mails com os valores atualmente implantados. Confira a rede, endpoints, secrets e tabelas pelo roteiro original antes de adotar.

**Use este caminho quando as stacks já existirem no ambiente de destino.** Não rode `prepare.sh` antes da adoção: é necessário importar os templates e parâmetros atualmente implantados.

Se os nomes diferirem dos padrões:

```bash
export MAIL_STACK=mail-sender-aws
export GMAIL_STACK=gmail-reader-aws
export WHATSAPP_STACK=whatsapp-notify
export BOT_STACK=loto-bot
export SCHEDULER_STACK=loto-scheduler-aws
bash scripts/adopt.sh
terraform state list
terraform show .local/adoption.tfplan
```

O script lê a configuração AWS, recupera o template original de cada stack e importa suas cinco identidades para o state. Os valores NoEcho de `SesFrom` e `MailTo` vêm de `SES_FROM` e `SCHEDULER_MAIL_TO`, pois a AWS retorna asteriscos. Informe os valores atualmente implantados. Não há atualização remota das stacks nesta etapa.

O plano de adoção deve ser sem mudanças de recursos. Se houver alterações, investigue antes do apply; não trate diferenças como obrigatórias. Capture tags/policies/opções de stack existentes na configuração Terraform, se aparecerem no plano.

Se a importação parar no meio, preserve `terraform.tfvars.json`, `prepared/` e state. Use `terraform state list` e importe somente os endereços faltantes:

```bash
terraform import aws_cloudformation_stack.mail "$MAIL_STACK"
terraform import aws_cloudformation_stack.gmail "$GMAIL_STACK"
terraform import aws_cloudformation_stack.whatsapp "$WHATSAPP_STACK"
terraform import aws_cloudformation_stack.bot "$BOT_STACK"
terraform import aws_cloudformation_stack.scheduler "$SCHEDULER_STACK"
terraform plan
```

Após a adoção, use este projeto para atualizar as stacks; não alterne com `sam deploy`. Os recursos internos continuam sob CloudFormation, portanto não devem ser importados individualmente no Terraform.

### Migração de um state com as quatro aplicações já adotadas

Se as quatro stacks já estiverem no state e o scheduler existir na AWS, mantenha os arquivos atuais e execute:

```bash
export SCHEDULER_STACK=loto-scheduler-aws
export SCHEDULER_MAIL_TO=destinatario-atual@example.com
bash scripts/adopt.sh --scheduler-only
terraform show .local/adoption.tfplan
```

Esse modo preserva a configuração e as releases existentes, salva configuração/state anteriores em `.local/adoption/`, captura o template e os parâmetros do scheduler e importa somente sua stack. Se a importação falhar após gravar a configuração, use `terraform import aws_cloudformation_stack.scheduler "$SCHEDULER_STACK"` para concluir, sem repetir a adoção. Revise o plano antes de aplicar: a URL privada gerenciada por este projeto usa porta 80 e pode exigir alinhar uma instalação com URL diferente.

Se o scheduler ainda não existir, acrescente `stack_names.scheduler` e `parameters.scheduler` a `terraform.tfvars.json` usando o exemplo e prepare as cinco aplicações; não tente importar uma stack inexistente. Mantenha os dois estados `DISABLED` até concluir a validação.

## 4. Preservar a versão atual

Antes de cada atualização, faça backup protegido de state e artefatos locais. Preserve também a chave SSH, `foundation/terraform.tfvars.json` e o state da fundação em armazenamento protegido, separado do Git:

```bash
mkdir -p .local
stamp=$(date -u +%Y%m%dT%H%M%SZ)
tar -czf ".local/before-$stamp.tgz" prepared terraform.tfvars.json
terraform state pull > ".local/state-$stamp.json"
test ! -f releases.auto.tfvars.json || cp releases.auto.tfvars.json ".local/releases-$stamp.json"
test ! -f maintenance.auto.tfvars.json || cp maintenance.auto.tfvars.json ".local/maintenance-$stamp.json"
```

Antes de preparar uma atualização, pause os dois agendamentos pelo Terraform usando os templates e releases ainda atuais:

```bash
printf '{"scheduler_paused":true}\n' > maintenance.auto.tfvars.json
terraform plan -out=.local/pause.tfplan
terraform show .local/pause.tfplan
terraform apply .local/pause.tfplan
bash scripts/check-scheduler.sh
```

Aplique somente se o plano corresponder à pausa esperada; resolva outras diferenças antes da manutenção. O arquivo mantém a pausa nos planos seguintes sem mudar `RunBetState`/`CheckDrawsState` configurados. Desative também qualquer scheduler local/externo que use o mesmo bot. Aguarde terminar as invocações e sessões em andamento: desabilitar schedules não cancela execuções já entregues. Confira logs, filas de falha e guards pelo guia operacional do scheduler, sem apagar locks para forçar a atualização.

Faça backup dos diretórios de dados das EC2 com as aplicações paradas e das duas tabelas DynamoDB antes de mudanças com risco de substituição. Para stacks novas, crie `maintenance.auto.tfvars.json` com a pausa antes do primeiro plano; a etapa de aplicar a pausa isoladamente vale para stacks já existentes.

## 5. Compilar e publicar artefatos

Os cinco diretórios devem ser repositórios Git independentes e estar limpos. Faça revisão dos arquivos rastreados antes do commit: `git archive` inclui tudo que está no commit, inclusive secrets caso tenham sido adicionados por engano.

```bash
bash scripts/prepare.sh
terraform plan -out=.local/deploy.tfplan
terraform show .local/deploy.tfplan
```

A preparação faz upload S3, mas não atualiza aplicações. Nas Lambdas, Docker compila as dependências para Linux. O scheduler usa o runtime de `parameters.scheduler.Runtime` em `terraform.tfvars.json` (padrão `python3.12`) e seu `check_artifact.py` valida os imports isolados em container antes do empacotamento. As outras duas Lambdas usam Python 3.12. O fluxo usa `sam build` e depois `sam package` sobre o template compilado, conforme a [documentação de build SAM](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-using-build.html). Nas EC2, o ZIP usa o commit Git, com chave S3 incluindo SHA256. Preserve objetos antigos para reversão.

Revise especialmente substituições EC2 e alterações de IAM, parâmetros e endpoints. O plano Terraform mostra a atualização da stack como unidade; ele **não descreve integralmente** as substituições dos recursos internos de CloudFormation. Compare os templates e parâmetros. Não considere `prevent_destroy` uma proteção dos volumes internos.

Mudanças de AMI, configuração de bootstrap, secrets ou variáveis de ambiente exigem planejamento próprio: o playbook atual troca código e preserva `/etc/*.env`. Não presuma que `apply` reaplicará UserData. Consulte OPERACAO.md.

## 6. Aplicar infraestrutura e código

Depois de revisar o plano:

```bash
terraform apply .local/deploy.tfplan
```

Após o apply concluir com sucesso, teste o envio direto pelo mail-sender (`loto-mail` na instalação com prefixo `loto`). O teste usa o nome da stack em `terraform.tfvars.json`, funcionando também para stacks adotadas sem depender de `.local/foundation.json`. Ele envia um e-mail real para `SES_FROM`, que deve estar verificado no SES da região configurada.

```bash
(
  set -euo pipefail
  umask 077
  mkdir -p .local
  MAIL_STACK=$(jq -er '.stack_names.mail | select(type == "string" and length > 0)' terraform.tfvars.json)
  MAIL_SENDER_FUNCTION_ARN=$(aws cloudformation describe-stacks \
    --stack-name "$MAIL_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionArn'].OutputValue | [0]" \
    --output text --profile "$AWS_PROFILE" --region "$AWS_REGION")
  [[ "$MAIL_SENDER_FUNCTION_ARN" == arn:*:lambda:* ]] || { echo 'FunctionArn ausente ou inválido'; }
  PAYLOAD=$(jq -n --arg to "$SES_FROM" \
    '{to:$to,subject:"Teste",body:"Teste do mail-sender",message_type:"TEXT"}')
  aws lambda invoke --function-name "$MAIL_SENDER_FUNCTION_ARN" \
    --invocation-type RequestResponse --cli-binary-format raw-in-base64-out \
    --payload "$PAYLOAD" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json .local/mail-response.json > .local/mail-invoke.json
  cat .local/mail-invoke.json
  cat .local/mail-response.json
  jq -e '.StatusCode == 200 and .FunctionError == null' .local/mail-invoke.json >/dev/null
  jq -e '.statusCode == 200' .local/mail-response.json >/dev/null
)
```

Continue somente se o bloco terminar sem erro e o e-mail chegar ao destinatário (confira também spam). O `StatusCode` da invocação, sozinho, não comprova sucesso do envio: confira também `FunctionError` e o `statusCode` retornado pela aplicação, conforme a [documentação de invocação Lambda](https://docs.aws.amazon.com/cli/latest/reference/lambda/invoke.html). Se houver falha, examine os dois arquivos em `.local/` e resolva antes de continuar.

Para exibir os logs do mail-sender dos últimos 10 minutos e acompanhar novas mensagens, execute o bloco abaixo. O nome da stack vem da mesma configuração usada no teste. O comando permanece acompanhando os logs até você pressionar `Ctrl+C`; use outro terminal se quiser acompanhar durante o teste.

```bash
(
  set -euo pipefail
  MAIL_STACK=$(jq -er '.stack_names.mail | select(type == "string" and length > 0)' terraform.tfvars.json)
  FUNCTION_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$MAIL_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue | [0]" \
    --output text --profile "$AWS_PROFILE" --region "$AWS_REGION")
  [[ -n "$FUNCTION_NAME" && "$FUNCTION_NAME" != None ]] || { echo 'FunctionName ausente'; }
  aws logs tail "/aws/lambda/$FUNCTION_NAME" --since 10m --follow \
    --profile "$AWS_PROFILE" --region "$AWS_REGION"
)
```

Após o mesmo apply concluir, teste também o Gmail reader (`loto-gmail` na instalação com prefixo `loto`). O secret OAuth deve estar preenchido e válido. A função aguarda por até 15 segundos uma **nova** mensagem com código de validação, correspondente ao remetente, assunto e expressão regular configurados; mensagens anteriores à chamada não atendem ao teste. Providencie a chegada dessa mensagem durante a espera para validar o sucesso completo.

```bash
(
  set -euo pipefail
  umask 077
  mkdir -p .local
  GMAIL_STACK=$(jq -er '.stack_names.gmail | select(type == "string" and length > 0)' terraform.tfvars.json)
  GMAIL_READER_FUNCTION_ARN=$(aws cloudformation describe-stacks \
    --stack-name "$GMAIL_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionArn'].OutputValue | [0]" \
    --output text --profile "$AWS_PROFILE" --region "$AWS_REGION")
  [[ "$GMAIL_READER_FUNCTION_ARN" == arn:*:lambda:* ]] || { echo 'FunctionArn ausente ou inválido'; }
  PAYLOAD='{"waitTimeoutSeconds":"15"}'
  aws lambda invoke --function-name "$GMAIL_READER_FUNCTION_ARN" \
    --invocation-type RequestResponse --cli-binary-format raw-in-base64-out \
    --payload "$PAYLOAD" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json .local/gmail-response.json > .local/gmail-invoke.json
  cat .local/gmail-invoke.json
  cat .local/gmail-response.json
  jq -e '.StatusCode == 200 and .FunctionError == null' .local/gmail-invoke.json >/dev/null
  jq -e '.statusCode == 200' .local/gmail-response.json >/dev/null
)
```

O sucesso completo retorna `statusCode=200` na resposta da aplicação, com o código encontrado no JSON de `body`. Se nenhuma nova mensagem válida chegar no prazo, a aplicação retorna `statusCode=500` com `VALIDATION_CODE_TIMEOUT`; isso, isoladamente, não comprova falha no deploy. Confira também os erros `AUTHENTICATION_ERROR` (OAuth) e `GMAIL_API_CONNECTION_ERROR` (conexão com a API), quando presentes, e resolva antes de considerar o teste aprovado.

Para exibir os logs do Gmail reader dos últimos 10 minutos e acompanhar novas mensagens, execute o bloco abaixo. Use outro terminal para acompanhar durante o teste e pressione `Ctrl+C` para encerrar o acompanhamento.

```bash
(
  set -euo pipefail
  GMAIL_STACK=$(jq -er '.stack_names.gmail | select(type == "string" and length > 0)' terraform.tfvars.json)
  FUNCTION_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$GMAIL_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue | [0]" \
    --output text --profile "$AWS_PROFILE" --region "$AWS_REGION")
  [[ -n "$FUNCTION_NAME" && "$FUNCTION_NAME" != None ]] || { echo 'FunctionName ausente'; }
  aws logs tail "/aws/lambda/$FUNCTION_NAME" --since 10m --follow \
    --profile "$AWS_PROFILE" --region "$AWS_REGION"
)
```

Depois dos testes, prossiga com a implantação nas EC2:

```bash
bash scripts/inventory.sh
ansible-playbook -i .local/inventory.json ansible/deploy.yml --syntax-check
ansible-playbook -i .local/inventory.json ansible/deploy.yml --limit whatsapp-notify
```

Após implantar o WhatsApp (`loto-whatsapp` com prefixo `loto`), execute o teste manual abaixo no terminal local, mantendo o scheduler pausado. Use um contato/grupo destinado à homologação: o teste envia uma mensagem real. Execute cada bloco e confira a resposta antes de avançar.

Prepare a conexão usando o nome da stack configurada e a mesma chave SSH usada no deploy:

```bash
REMOTE_USER='ubuntu'
KNOWN_HOSTS_FILE="$PWD/.local/known_hosts"
WHATSAPP_STACK=$(jq -er '.stack_names.whatsapp | select(type == "string" and length > 0)' terraform.tfvars.json)
INSTANCE_ID=$(aws cloudformation describe-stack-resource \
  --stack-name "$WHATSAPP_STACK" --logical-resource-id ApplicationInstance \
  --query StackResourceDetail.PhysicalResourceId --output text \
  --profile "$AWS_PROFILE" --region "$AWS_REGION")
INSTANCE_IPV6=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' \
  --output text --profile "$AWS_PROFILE" --region "$AWS_REGION")
SSH_OPTS=(-i "$SSH_KEY" -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE")
```

Confirme que `INSTANCE_ID` e `INSTANCE_IPV6` contêm valores válidos. O inventário/Ansible usa esse mesmo arquivo de hosts conhecidos. Se o SSH pedir confirmação de uma chave nova, confira a identidade da instância antes de aceitar.

Consulte o status e abra a sessão em modo headless (sem interface gráfica na EC2):

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -fi -sS --max-time 30 'http://127.0.0.1/whatsapp/session/status'"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -fi -sS --max-time 120 'http://127.0.0.1/whatsapp/session/start?headless=true&timeoutInSeconds=60'"
```

Na primeira autenticação, capture e baixe o QR code. Se a sessão já estiver autenticada, pule a captura e prossiga para o envio. O arquivo local é criado por `mktemp` e mantido para receber a cópia, sem removê-lo antes do `scp`:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "umask 077; curl -fSs --max-time 30 'http://127.0.0.1/whatsapp/session/qrcode' -o /home/ubuntu/whatsapp-qr.png"
QR_CODE_FILE=$(mktemp --suffix=.png)
scp "${SSH_OPTS[@]}" "$REMOTE_USER@[$INSTANCE_IPV6]:/home/ubuntu/whatsapp-qr.png" "$QR_CODE_FILE"
eog "$QR_CODE_FILE"
```

`eog` é um visualizador local de imagens; se não estiver instalado, abra o arquivo indicado por `echo "$QR_CODE_FILE"` em outro visualizador. Escaneie o QR code pelo WhatsApp no celular, em **Aparelhos conectados**, antes de continuar. Se expirar, capture e copie novamente. Confirme a autenticação consultando o status:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -fi -sS --max-time 30 'http://127.0.0.1/whatsapp/session/status'"
```

Defina o nome exato do contato/grupo de homologação e envie a mensagem. O `jq` monta o JSON e o SSH o encaminha pela entrada padrão do `curl`:

```bash
TEST_CONTACT='Notificação via App'
TEST_MESSAGE="Mensagem de teste em $(date '+%Y-%m-%d %H:%M:%S')"
TEST_JSON=$(jq -n --arg contact "$TEST_CONTACT" --arg message "$TEST_MESSAGE" \
  '{contact:$contact,message:$message}')
printf '%s' "$TEST_JSON" | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -fi -sS --max-time 120 -X POST 'http://127.0.0.1/whatsapp/messages/send' -H 'Content-Type: application/json; charset=utf-8' --data-binary @-"
```

Confira a resposta HTTP e o recebimento da mensagem. Ao terminar, feche a sessão de teste e remova as imagens temporárias, inclusive se alguma etapa anterior falhar:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -fi -sS --max-time 30 'http://127.0.0.1/whatsapp/session/stop'"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" 'rm -f /home/ubuntu/whatsapp-qr.png'
if [[ -n "${QR_CODE_FILE:-}" ]]; then rm -f -- "$QR_CODE_FILE"; unset QR_CODE_FILE; fi
```

Para acompanhar os logs, reutilize as variáveis e `SSH_OPTS` acima no mesmo terminal. O comando mostra as últimas 100 linhas e acompanha novas mensagens até `Ctrl+C`:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'sudo journalctl -u whatsapp-notify -n 100 -f --full -o short-iso-precise'
```

Se precisar de detalhes em `DEBUG`, registre primeiro o nível atual e depois altere a configuração. O restart interrompe a sessão ativa; faça isso antes de iniciar o teste ou após encerrá-lo. Para acompanhar os logs durante o teste, use outro terminal com a conexão preparada.

```bash
PREVIOUS_LOG_LEVEL=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -n 's/^LOG_LEVEL=//p' /etc/whatsapp-notify.env")
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=DEBUG/' /etc/whatsapp-notify.env && sudo systemctl restart whatsapp-notify"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'sudo journalctl -u whatsapp-notify -n 100 -f --full -o short-iso-precise'
```

O arquivo gerado pelo bootstrap contém `LOG_LEVEL=INFO`. Após encerrar o acompanhamento com `Ctrl+C`, restaure o nível anterior no mesmo terminal e reinicie o serviço:

```bash
case "$PREVIOUS_LOG_LEVEL" in
  DEBUG|INFO|WARNING|ERROR|CRITICAL) ;;
  *) echo 'Nível anterior inesperado; confira LOG_LEVEL no arquivo remoto antes de restaurar'; false ;;
esac && ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=$PREVIOUS_LOG_LEVEL/' /etc/whatsapp-notify.env && sudo systemctl restart whatsapp-notify"
```

Depois de validar o WhatsApp, prossiga com o bot e a verificação conjunta:

```bash
ansible-playbook -i .local/inventory.json ansible/deploy.yml --limit loto-bot
bash scripts/check.sh
```

O Terraform atualiza o scheduler depois das dependências do bot e do mail-sender e consulta o IP privado atual da EC2. Mantenha `scheduler_paused=true` durante toda a implantação; a stack pronta não significa que o código EC2 e o túnel já estejam validados. A sequência explícita do Ansible garante WhatsApp antes do bot. CloudFormation faz bootstrap das novas EC2; Ansible publica releases nas existentes. O playbook verifica SHA256, preserva diretórios de sessão, recarrega Nginx e testa 8000/80. Se a nova versão falhar, restaura o caminho anterior e encerra com erro.

## 7. Túnel SOCKS sem bloquear a execução

Se já houver um serviço de túnel SOCKS configurado, reutilize-o; não inicie outro túnel na mesma porta 1080. Caso contrário, use `examples/loto-socks.service`.

Descubra o IPv6 atual do bot:

```bash
BOT_ID=$(terraform output -json stack_outputs | jq -r '.bot.InstanceId')
aws ec2 describe-instances --instance-ids "$BOT_ID" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' --output text
```

Preencha endereço e caminhos no arquivo de exemplo e instale:

```bash
mkdir -p ~/.config/systemd/user
cp examples/loto-socks.service ~/.config/systemd/user/loto-socks.service
systemctl --user daemon-reload
systemctl --user enable --now loto-socks.service
systemctl --user status loto-socks.service --no-pager
journalctl --user -u loto-socks.service -n 30 --no-pager
```

O serviço executa em segundo plano; o comando retorna sem bloquear o roteiro. Sob systemd, SSH não usa `-f`. Para permanecer após logout, `loginctl enable-linger "$USER"` é opcional; suspensão/desligamento ainda interrompem o túnel.

Dentro do bot, confira o socket e a saída:

```bash
ss -lnt | grep '127.0.0.1:1080'
curl -fsS --max-time 15 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

### Teste manual do bot após o deploy e o túnel

Com o deploy da etapa 6 concluído, execute os blocos abaixo no terminal local, mantendo `scheduler_paused=true` e os schedulers externos parados. A conexão agora deve apontar para o **bot**, não para a EC2 do WhatsApp. Confira cada resposta antes de avançar.

```bash
REMOTE_USER='ubuntu'
KNOWN_HOSTS_FILE="$PWD/.local/known_hosts"
BOT_STACK=$(jq -er '.stack_names.bot | select(type == "string" and length > 0)' terraform.tfvars.json)
INSTANCE_ID=$(aws cloudformation describe-stack-resource \
  --stack-name "$BOT_STACK" --logical-resource-id ApplicationInstance \
  --query StackResourceDetail.PhysicalResourceId --output text \
  --profile "$AWS_PROFILE" --region "$AWS_REGION")
INSTANCE_IPV6=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' \
  --output text --profile "$AWS_PROFILE" --region "$AWS_REGION")
SSH_OPTS=(-i "$SSH_KEY" -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE")
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 30 'http://127.0.0.1/api/v1/sessions/status'"
```

Confirme os valores de `INSTANCE_ID` e `INSTANCE_IPV6`. Reutilize o túnel systemd da etapa 7. Como alternativa temporária, se ainda não houver túnel, o bloco abaixo cria um com socket de controle. Ele preserva qualquer processo que já escute na porta 1080; não execute `fuser -k` para liberar a porta. Se houver um listener, valide a saída SOCKS nos comandos seguintes antes de considerá-lo funcional.

```bash
TUNNEL_SOCKET="$PWD/.local/loto-control.sock"
(
  set -euo pipefail
  if ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
    "ss -H -lnt 'sport = :1080' | grep -q ."; then
    echo 'Porta remota 1080 em uso; confira e reutilize o túnel existente.'
  else
    [[ ! -e "$TUNNEL_SOCKET" && ! -S "$TUNNEL_SOCKET" ]] || {
      echo 'Socket já existe; confira o túnel antes de iniciar outro' >&2
    }
    ssh "${SSH_OPTS[@]}" -f -N -T -M -S "$TUNNEL_SOCKET" \
      -o ControlPersist=no -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -R 127.0.0.1:1080 "$REMOTE_USER@$INSTANCE_IPV6"
    ssh "${SSH_OPTS[@]}" -S "$TUNNEL_SOCKET" -O check "$REMOTE_USER@$INSTANCE_IPV6"
  fi
)
```

Valide a saída pelo SOCKS e o acesso HTTP ao portal:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'curl -fsS --max-time 20 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org && echo'
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'curl -sS -L --max-time 20 --socks5-hostname 127.0.0.1:1080 -o /dev/null -w "HTTP %{http_code}\n" "https://www.loteriasonline.caixa.gov.br/silce-web/#/termos-de-uso"'
```

O segundo comando verifica a resposta HTTP inicial do site; o fragmento `#/termos-de-uso` é interpretado pelo navegador e não testa a navegação nem o login. Abra a sessão do bot, confira o status e encerre para validar o ciclo básico:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 120 'http://127.0.0.1/api/v1/sessions/start'"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 30 'http://127.0.0.1/api/v1/sessions/status'"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 60 'http://127.0.0.1/api/v1/sessions/stop'"
```

Para consultar apostas e conferir resultados, abra novamente a sessão:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 120 'http://127.0.0.1/api/v1/sessions/start'"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 30 'http://127.0.0.1/api/v1/sessions/status'"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'curl -fsS --max-time 120 http://127.0.0.1/api/v1/history/bets' | jq .
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'curl -fsS --max-time 120 http://127.0.0.1/api/v1/bets' | jq .
```

**Teste opcional com pagamento real:** execute o bloco seguinte somente quando quiser efetivar uma aposta QUINA. Ele ativa `CONFIRM_PAYMENT=true`, reinicia o bot e chama `/api/v1/bets/run`; não é um health check. Alinhe também `parameters.bot.ConfirmPayment` em `terraform.tfvars.json` com o valor desejado e revise o próximo plano. O restart interrompe a sessão anterior, por isso o bloco a abre novamente. Confira a resposta e o histórico antes de repetir uma chamada que falhe ou exceda o timeout, pois a aposta pode já ter sido realizada.

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -i 's/^CONFIRM_PAYMENT=.*/CONFIRM_PAYMENT=true/' /etc/loto-bot.env &&
   sudo grep -qx 'CONFIRM_PAYMENT=true' /etc/loto-bot.env &&
   sudo systemctl restart loto-bot && sudo systemctl is-active loto-bot"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 120 'http://127.0.0.1/api/v1/sessions/start'"
TEST_JSON=$(jq -n --arg selected_lottery_modality QUINA \
  '{selected_lottery_modality:$selected_lottery_modality}')
printf '%s' "$TEST_JSON" | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 120 -X POST 'http://127.0.0.1/api/v1/bets/run' -H 'Content-Type: application/json; charset=utf-8' --data-binary @-"
```

Para conferir resultados, use a data de São Paulo, como a aplicação. Ajuste o intervalo se quiser incluir apostas de outros dias. `month_year` aceita `LAST_7_DAYS`, não `ALL`. O comando preserva o corpo de respostas HTTP de erro:

```bash
TEST_DATE=$(TZ=UTC date '+%Y-%m-%d')
TEST_JSON=$(jq -n --arg day "$TEST_DATE" '{
  lottery_modality:"ALL",start_date:$day,end_date:$day,
  bet_type:"INDIVIDUAL",draw_type:"ALL",month_year:"LAST_7_DAYS",status:"ALL"
}')
printf '%s' "$TEST_JSON" | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 120 -X POST 'http://127.0.0.1/api/v1/bets/check_draws' -H 'Content-Type: application/json; charset=utf-8' --data-binary @-"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "curl -i -sS --max-time 60 'http://127.0.0.1/api/v1/sessions/stop'"
```

Se habilitou pagamento somente para o teste, restaure `CONFIRM_PAYMENT=false` e mantenha o parâmetro Terraform alinhado antes de liberar a operação:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -i 's/^CONFIRM_PAYMENT=.*/CONFIRM_PAYMENT=false/' /etc/loto-bot.env &&
   sudo grep -qx 'CONFIRM_PAYMENT=false' /etc/loto-bot.env &&
   sudo systemctl restart loto-bot && sudo systemctl is-active loto-bot"
```

Para exibir os logs do bot, use a conexão preparada acima. `Ctrl+C` encerra o acompanhamento:

```bash
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'sudo journalctl -u loto-bot -n 100 -f --full -o short-iso-precise'
```

Se precisar de `DEBUG`, registre o nível atual e altere o arquivo de ambiente. O restart interrompe a sessão ativa; faça isso antes de iniciar o teste ou após encerrá-lo. Para acompanhar durante o teste, prepare a conexão em outro terminal.

```bash
PREVIOUS_BOT_LOG_LEVEL=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -n 's/^LOG_LEVEL=//p' /etc/loto-bot.env")
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=DEBUG/' /etc/loto-bot.env && sudo systemctl restart loto-bot"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  'sudo journalctl -u loto-bot -n 100 -f --full -o short-iso-precise'
```

Após `Ctrl+C`, restaure o nível anterior no mesmo terminal (o bootstrap usa `INFO`):

```bash
case "$PREVIOUS_BOT_LOG_LEVEL" in
  DEBUG|INFO|WARNING|ERROR|CRITICAL) ;;
  *) echo 'Nível anterior inesperado; confira LOG_LEVEL no arquivo remoto antes de restaurar'; false ;;
esac && ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" \
  "sudo sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=$PREVIOUS_BOT_LOG_LEVEL/' /etc/loto-bot.env && sudo systemctl restart loto-bot"
```

Mantenha o túnel necessário à operação ativo. Se criou apenas o túnel temporário para homologação e ele não será usado pela operação, encerre-o pelo socket correspondente:

```bash
ssh "${SSH_OPTS[@]}" -S "$TUNNEL_SOCKET" -O exit "$REMOTE_USER@$INSTANCE_IPV6"
```

## 8. Validar e liberar operação

`check.sh` deve finalizar sem erros. `SESSAO_FECHADA` com HTTP 200 indica API acessível; autentique WhatsApp pelo fluxo da aplicação antes de depender do envio. Não confunda conectividade com sessão autenticada.

Verifique os logs de ambas as aplicações e a versão ativa em `readlink -f /opt/NOME/app`. Não teste apostas/pagamentos como health check. Confira também logs e filas do scheduler. `check.sh` inclui `check-scheduler.sh`, que não invoca jobs; para conferir só o scheduler, execute-o diretamente.

## 9. Habilitar o loto-scheduler

Depois das validações da etapa 8, habilite os agendamentos pelo Terraform. Há dois controles: `RunBetState`/`CheckDrawsState` precisam estar em `ENABLED` e `scheduler_paused` precisa ser `false`. Apenas remover a pausa não ativa os agendamentos de uma instalação nova, pois ambos começam em `DISABLED`.

Mantenha o túnel SOCKS funcionando e os schedulers locais/externos dos mesmos jobs parados. Confira os horários em `RunBetCron` e `CheckDrawsCron`, as modalidades em `RunModality` e `CheckModality` e a configuração de pagamento do bot. `RunBetState=ENABLED` agenda a execução automática do fluxo de aposta; se `CONFIRM_PAYMENT=true` estiver ativo no bot, esse fluxo pode efetivar pagamentos.

O bloco abaixo habilita **os dois jobs** em `terraform.tfvars.json`, preservando os demais parâmetros. Para habilitar somente a conferência de resultados, use `"DISABLED"` em `RunBetState` e mantenha `CheckDrawsState` em `"ENABLED"`.

```bash
(
  set -euo pipefail
  umask 077
  config=$(mktemp .local/enable-scheduler.XXXXXX)
  trap 'rm -f -- "$config"' EXIT
  jq '.parameters.scheduler.RunBetState = "ENABLED" |
      .parameters.scheduler.CheckDrawsState = "ENABLED"' \
    terraform.tfvars.json > "$config"
  mv -- "$config" terraform.tfvars.json
)
printf '{"scheduler_paused":false}\n' > maintenance.auto.tfvars.json
terraform plan -out=.local/resume.tfplan
terraform show .local/resume.tfplan
```

Revise o plano para confirmar que a habilitação tem somente as mudanças esperadas, inclusive os dois estados em `ENABLED` quando ambos os jobs forem desejados. Depois da revisão, aplique e confira:

```bash
terraform apply .local/resume.tfplan
bash scripts/check-scheduler.sh
```

Para a habilitação dos dois jobs, a verificação deve exibir `RunBetScheduleName: ENABLED` e `CheckDrawsScheduleName: ENABLED`. O script também confere a Lambda ativa, a tabela disponível e o fuso dos agendamentos; não invoca jobs. Os jobs executarão nos horários configurados. Os crons usam `America/Sao_Paulo`; o conversor original interpreta segunda-feira como 0, portanto `1,3,5` corresponde a terça, quinta e sábado.

Para exibir os logs do scheduler dos últimos 10 minutos e acompanhar novas mensagens, execute o bloco abaixo. O nome da função é consultado nos outputs da stack configurada em `terraform.tfvars.json`. Use outro terminal para acompanhar as execuções e pressione `Ctrl+C` para encerrar o acompanhamento.

```bash
(
  set -euo pipefail
  SCHEDULER_STACK=$(jq -er '.stack_names.scheduler | select(type == "string" and length > 0)' terraform.tfvars.json)
  FUNCTION_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$SCHEDULER_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue | [0]" \
    --output text --profile "$AWS_PROFILE" --region "$AWS_REGION")
  [[ -n "$FUNCTION_NAME" && "$FUNCTION_NAME" != None ]] || { echo 'FunctionName ausente'; }
  aws logs tail "/aws/lambda/$FUNCTION_NAME" --since 10m --follow \
    --profile "$AWS_PROFILE" --region "$AWS_REGION"
)
```

Na adoção, os estados anteriores são preservados até você alterá-los; confira se deseja habilitar ambos antes de executar o bloco. Para pausar novamente sem perder os estados configurados, grave `scheduler_paused=true` em `maintenance.auto.tfvars.json`, gere e revise um novo plano e aplique-o, conforme a etapa 4.

## Stacks novas sobre uma fundação externa existente

Este caminho alternativo é para quem já possui a fundação fora de `foundation/`, mas ainda não possui as stacks. Copie `examples/terraform.tfvars.json` para `terraform.tfvars.json` e preencha todos os IDs/ARNs reais. Configure `ARTIFACT_BUCKET` com seu bucket privado existente e `SSH_KEY` com a chave das EC2. Mantenha `ConfirmPayment=false` e os dois schedules `DISABLED`. Execute `terraform init`, crie `maintenance.auto.tfvars.json` com `scheduler_paused=true` e prossiga na etapa 5, sem adoção.

Os parâmetros `VpcId`, `SubnetIds`, `RouteTableIds` e os Security Groups devem pertencer à mesma rede. `LambdaEndpointSecurityGroupId` é o SG do endpoint Lambda. Se a fundação já possui esse endpoint, use `UseLambdaVpcEndpoint=false` no bot; se o bot o criar, obtenha seu SG antes de configurar o scheduler. Nunca crie dois endpoints Lambda com Private DNS na mesma VPC. Para endpoint DynamoDB existente, mantenha `CreateDynamoGateway=false` e confira as rotas.

As tabelas precisam existir antes das aplicações. Para tabelas externas, use os scripts `create-dynamodb-aws.sh` dos respectivos repositórios, com os nomes dos parâmetros do bot e scheduler, instalando suas dependências conforme os guias. A tabela de apostas usa `bet_id` String; a de execuções usa `pk` String, sem sort key/índices, com TTL `expires_at`. Ambas usam `PAY_PER_REQUEST`. Não execute esses scripts para recursos administrados por `foundation/`.
