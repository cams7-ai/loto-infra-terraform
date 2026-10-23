# Criar a infraestrutura básica do zero

Execute depois da etapa 1 de [EXECUCAO.md](EXECUCAO.md), com as ferramentas de [INSTALACAO.md](INSTALACAO.md). Aqui a fundação passa a ser gerenciada por Terraform em `foundation/`; as aplicações são implantadas pelo Terraform da raiz. Não execute `sam deploy`.

A arquitetura conserva uma VPC `10.77.0.0/16`, subnet `10.77.1.0/24` com IPv6, internet gateway e saída `::/0`, sem IPv4 público ou NAT. Há endpoints de interface para CloudFormation, Secrets Manager e Lambda, e gateway endpoints para S3/DynamoDB. O endpoint Lambda é criado na fundação; o bot será configurado com `UseLambdaVpcEndpoint=false` e o scheduler com `CreateDynamoGateway=false`, evitando duplicação. HTTPS nos endpoints é permitido a partir do CIDR privado da VPC; SSH nas EC2 será limitado ao seu IPv6 `/128` pelos templates das aplicações.

Os endpoints de interface têm cobrança por hora/tráfego, mesmo sem aplicações ativas. Bucket/versionamento, tabelas sob demanda/PITR e Secrets Manager também têm custos conforme armazenamento e uso. Revise as páginas de preços de [PrivateLink](https://aws.amazon.com/privatelink/pricing/), [S3](https://aws.amazon.com/s3/pricing/), [DynamoDB](https://aws.amazon.com/dynamodb/pricing/) e [Secrets Manager](https://aws.amazon.com/secrets-manager/pricing/). Para produção, considere logs de acesso/data events do S3 e DynamoDB e alarmes CloudWatch; não fazem parte desta fundação inicial.

## 1. Chave local e parâmetros

Na raiz deste projeto, mantenha exportados `AWS_PROFILE`, `AWS_REGION`, `EXPECTED_ACCOUNT_ID`, `SOURCE_ROOT`, `SSH_KEY`, `SES_FROM` e `SCHEDULER_MAIL_TO` da etapa 1. Confirme a conta:

```bash
umask 077
actual_account=$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)
[[ "$actual_account" == "$EXPECTED_ACCOUNT_ID" ]] || { echo 'Conta AWS incorreta'; }
mkdir -p .local
```

Gere uma chave exclusiva para as duas EC2. `SSH_KEY` deve ser um caminho absoluto. Se ela já existir de uma tentativa anterior, preserve-a e confirme a chave pública correspondente; não sobrescreva:

```bash
[[ ! -e "$SSH_KEY" && ! -e "$SSH_KEY.pub" ]] || { echo "Preserve a chave existente e confira o arquivo .pub"; }
ssh-keygen -t ed25519 -f "$SSH_KEY" -C loto-infra
chmod 600 "$SSH_KEY"
```

Escolha uma senha para a chave e use `ssh-agent`/`ssh-add "$SSH_KEY"` antes do Ansible e do túnel. A fundação importa apenas o arquivo `.pub`; a chave privada não é criada pela AWS nem armazenada no state.

Obtenha o IPv6 público da máquina que fará SSH e valide seu `/128`:

```bash
LOCAL_PUBLIC_IPV6=$(curl -6 -fsS --max-time 20 https://api64.ipify.org)
python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$LOCAL_PUBLIC_IPV6"
```

Se sua máquina não possui IPv6 funcional, resolva isso antes de continuar: o roteiro usa IPv6 para SSH e para o túnel reverso.

Crie os parâmetros da fundação **somente na primeira execução**. O nome `loto` determina nomes dos recursos/bucket/stacks; ajuste-o antes do primeiro plano se precisar de outro ambiente. Não altere esse nome depois de implantar sem revisar substituições.

```bash
(set -o noclobber
jq -n --arg account "$EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" \
  --arg public_key "$SSH_KEY.pub" --arg ssh "$LOCAL_PUBLIC_IPV6/128" --arg email "$SES_FROM" \
  '{account_id:$account,region:$region,name:"loto",ssh_public_key_path:$public_key,ssh_ipv6_cidr:$ssh,ses_from:$email}' \
  > foundation/terraform.tfvars.json
)
```

## 2. Criar e conferir a fundação

```bash
terraform -chdir=foundation init
terraform -chdir=foundation validate
bash scripts/plan-foundation.sh
terraform -chdir=foundation show foundation.tfplan
```

O script consulta os nomes exatos `<name>/application` e `<name>/gmail-oauth-token` na conta/região configuradas em `foundation/`. Se a secret existe, importa seu ARN para o state antes do plano; se já está no state, não repete a importação. Se estiver agendada para exclusão, cancela esse agendamento com `restore-secret` antes de reutilizá-la. Somente `ResourceNotFoundException` é tratado como ausência; erros de permissão, credenciais ou rede interrompem a execução. Os valores e versões das secrets são preservados e não são lidos pelo script. Antes de importar em um state com recursos, salva um backup em `.local/foundation-before-secret-import.*.tfstate`.

Use o mesmo perfil AWS do provider. O script lê defaults, arquivos tfvars de `foundation/` e `TF_VAR_*` com `terraform console`; não aceita argumentos de sobrescrita. Ele precisa de `secretsmanager:DescribeSecret` e, para secrets com exclusão agendada, `secretsmanager:RestoreSecret`, além das permissões usuais de importação/plano. Reutilize apenas secrets que pertençam a este ambiente e não sejam gerenciadas por outro state. A restauração e a importação acontecem ao executar o script; o plano ainda exige revisão e apply explícito. Veja [DescribeSecret](https://docs.aws.amazon.com/cli/latest/reference/secretsmanager/describe-secret.html), [RestoreSecret](https://docs.aws.amazon.com/cli/latest/reference/secretsmanager/restore-secret.html) e [importação Terraform](https://developer.hashicorp.com/terraform/cli/import).

Revise conta, região, IPv6 `/128`, chave e nomes. O plano deve criar os recursos ausentes: rede/endpoints, bucket privado com AES256/versionamento/ACLs desabilitadas, chave pública EC2, dois contêineres de secrets, identidade SES e duas tabelas com PITR/proteção de exclusão. Secrets importadas não devem aparecer para criação; revise eventuais atualizações de metadados. As tabelas usam criptografia padrão do DynamoDB com chave de propriedade da AWS. A de apostas usa `bet_id` String; a de execuções usa `pk` String, sem sort key/índices, TTL `expires_at`. Não há criação de aplicações nesta fase.

```bash
terraform -chdir=foundation apply foundation.tfplan &&
  terraform -chdir=foundation output -json configuration > .local/foundation.json &&
  export ARTIFACT_BUCKET=$(jq -er '.artifact_bucket' .local/foundation.json)
```

Se houver falha parcial, preserve `foundation/terraform.tfstate` e a chave. Corrija a causa e execute novamente `bash scripts/plan-foundation.sh`, revise o novo plano e continue; não reutilize o plano antigo, reinicie em outro state ou exclua recursos manualmente. A reutilização automática cobre somente as duas secrets; os demais recursos existentes exigem importação explícita. Não consulte o output `configuration` após um apply com erro: ele pode ainda não existir, como no log de criação parcial.

O state da fundação e o da raiz são independentes e começam locais. Faça backup protegido de ambos. O bucket de artefatos não é um backend de state automaticamente; configure um backend protegido conforme [OPERACAO.md](OPERACAO.md) se necessário, com chaves de state distintas para fundação e aplicações.

## 3. Preencher os secrets fora do Terraform

Terraform gerencia somente os contêineres/ARNs dos secrets. **Antes de implantar aplicações**, confira `AWSCURRENT` conforme os comandos ao final desta seção. Para secrets novas, publique uma versão válida em cada uma; para as reutilizadas, preserve as versões existentes e só atualize valores se necessário. Não adicione valores secretos a `.tfvars`, argumentos literais, commits ou logs.

Para o bot, prepare o `.env` local do repositório `loto-bot` conforme seu guia, preenchendo `BETTOR_CPF`, `BETTOR_PASSWORD`, `CREDIT_CARD_LAST_DIGITS`, `CREDIT_CARD_SECURITY_CODE` e `MAIL_TO`. Instale as dependências do projeto, incluindo `python-dotenv`, no ambiente virtual desse repositório. O script da referência lê esse `.env` e produz o JSON esperado:

```bash
bash "$SOURCE_ROOT/loto-bot/scripts/create-application-secret.sh" "file://$PWD/.local/application-secret.json"
APPLICATION_SECRET_ARN=$(jq -er '.application_secret_arn' .local/foundation.json)
aws secretsmanager put-secret-value --secret-id "$APPLICATION_SECRET_ARN" \
  --secret-string "file://$PWD/.local/application-secret.json" --query VersionId --output text
```

Para o Gmail, configure as credenciais OAuth Google conforme o guia de `gmail-reader-aws`. Na primeira autenticação há interação pelo navegador; ela não pode ser substituída pelo Terraform. O roteiro original usa:

```bash
(
  cd "$SOURCE_ROOT/gmail-reader-aws"
  python3 -m venv .venv
  source .venv/bin/activate
  python -m pip install -r src/requirements.txt
  python -m pip install -e '.[dev]'
  export PYTHONPATH=src
  python -c 'from config import Settings; from infra import GmailAuthenticator; GmailAuthenticator(Settings()).authenticate()'
)
```

Confirme o caminho real de `token.json` gerado pelo projeto. Para o caminho da referência:

```bash
GMAIL_TOKEN_PATH="$SOURCE_ROOT/gmail-reader-aws/GmailAPI/token.json"
test -s "$GMAIL_TOKEN_PATH"
GMAIL_SECRET_ARN=$(jq -er '.gmail_secret_arn' .local/foundation.json)
aws secretsmanager put-secret-value --secret-id "$GMAIL_SECRET_ARN" \
  --secret-string "file://$GMAIL_TOKEN_PATH" --query VersionId --output text
```

Confira a existência de `AWSCURRENT` sem imprimir o conteúdo dos secrets:

```bash
aws secretsmanager list-secret-version-ids --secret-id "$APPLICATION_SECRET_ARN" \
  --query 'Versions[].VersionStages' --output json
aws secretsmanager list-secret-version-ids --secret-id "$GMAIL_SECRET_ARN" \
  --query 'Versions[].VersionStages' --output json
```

Cada secret deve ter uma versão com estágio `AWSCURRENT`. Proteja os arquivos locais; `.local/` é ignorado pelo Git. O token e `.env` nos repositórios externos também devem permanecer fora do versionamento.

## 4. Verificar SES

O apply solicita a identidade de `SES_FROM`. Abra o e-mail de verificação e confirme o link. Depois:

```bash
aws sesv2 get-email-identity --email-identity "$SES_FROM" --query VerificationStatus --output text
```

Continue somente com `SUCCESS`. No sandbox SES, verifique também os destinatários usados pelo bot/scheduler. Se `SCHEDULER_MAIL_TO` ainda não estiver verificado, solicite sua identidade e confirme o link:

```bash
aws sesv2 create-email-identity --email-identity "$SCHEDULER_MAIL_TO"
aws sesv2 get-email-identity --email-identity "$SCHEDULER_MAIL_TO" --query VerificationStatus --output text
```

Esse último cadastro é manual, externo ao state da fundação. Se já estiver verificado, não repita a criação. Outros destinatários do secret do bot precisam da mesma verificação no sandbox.

## 5. Gerar a configuração das aplicações

```bash
bash scripts/configure-new.sh
```

O script confere conta/região dos outputs e gera `terraform.tfvars.json` e `maintenance.auto.tfvars.json`, sem sobrescrever configurações existentes. Preenche rede, AMI Ubuntu 24.04 amd64 consultada no SSM, chave, tabelas, secrets e endpoint Lambda; mantém `ConfirmPayment=false` e ambos os schedules `DISABLED`, com pausa ativa. Ele não lê o conteúdo dos secrets nem aplica mudanças AWS.

Revise os parâmetros antes do primeiro plano. Retorne à etapa 3 de [EXECUCAO.md](EXECUCAO.md), execute `terraform init` na raiz e siga a etapa 5 para build/publicação. `adopt.sh` é exclusivo de stacks previamente implantadas e não faz parte desta instalação.

Em um novo terminal, reexporte as variáveis da etapa 1 e recupere o bucket com `export ARTIFACT_BUCKET=$(terraform -chdir=foundation output -json configuration | jq -er '.artifact_bucket')`. Preserve a chave SSH e os dois states.

Referências técnicas: [gateway S3](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html), [endpoints no provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) e [tabelas no provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table).
