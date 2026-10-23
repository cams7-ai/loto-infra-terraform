# Tutorial simples dos comandos Terraform do LotoBot

Este guia explica os comandos usados neste repositório. Para executar uma instalação completa, siga também [INSTALACAO.md](INSTALACAO.md), [FUNDACAO.md](FUNDACAO.md) e [EXECUCAO.md](EXECUCAO.md), que incluem os pré-requisitos e as verificações de cada etapa.

## 1. Entenda o que o Terraform controla

O Terraform compara os arquivos de configuração com a infraestrutura e calcula o que precisa mudar. Ele mantém um **state**, um registro que associa os recursos da configuração aos recursos reais na AWS.

Neste projeto existem dois conjuntos independentes:

| Diretório | Responsabilidade | State local inicial |
|---|---|---|
| Raiz do projeto | Cinco stacks: mail, Gmail, WhatsApp, bot e scheduler | `terraform.tfstate` |
| `foundation/` | Rede, bucket, chave pública SSH, contêineres de secrets, tabelas e identidade SES | `foundation/terraform.tfstate` |

Na raiz, o Terraform administra stacks CloudFormation. Os recursos internos, como EC2 e Lambda, continuam sob responsabilidade do CloudFormation. A atualização do código das EC2 também depende do Ansible.

Os comandos abaixo partem da **raiz deste repositório**. A opção `-chdir=foundation` manda o Terraform trabalhar em `foundation/`:

```bash
terraform init
terraform -chdir=foundation init
```

Cada comando inicializa um diretório diferente. Um `apply` na raiz não aplica a fundação, e vice-versa. Os states começam locais; um backend remoto pode ser configurado conforme [OPERACAO.md](OPERACAO.md).

## 2. Antes de começar

O projeto requer Terraform `>= 1.10` e `< 2.0`, com provider AWS `6.x`, conforme os arquivos `versions.tf`.

```bash
terraform version
```

Esse comando mostra a versão instalada. Para instalar as ferramentas e configurar as credenciais, use [INSTALACAO.md](INSTALACAO.md). Antes de um plano conectado à AWS, confira o perfil, a conta e a região do roteiro de execução.

Os arquivos de entrada têm estas funções:

| Arquivo | Para que serve |
|---|---|
| `*.tf` | Define os recursos, variáveis e saídas |
| `terraform.tfvars.json` | Configura as aplicações neste ambiente |
| `foundation/terraform.tfvars.json` | Configura a fundação |
| `releases.auto.tfvars.json` | Guarda parâmetros dos artefatos preparados pelo script |
| `maintenance.auto.tfvars.json` | Controla a pausa do scheduler |
| `.terraform.lock.hcl` | Fixa a seleção e os checksums dos providers |

O Terraform carrega automaticamente `terraform.tfvars.json` e os arquivos `*.auto.tfvars.json` do diretório em que está trabalhando. Por isso, uma alteração no arquivo de manutenção afeta os próximos planos da raiz. O arquivo de releases também pode sobrescrever parâmetros de artefatos da configuração base.

## 3. `init`: preparar o diretório

```bash
terraform init
```

Instala os providers necessários e inicializa o backend que guarda o state. Execute na primeira utilização e novamente quando a configuração do backend ou dos providers exigir inicialização.

Para a fundação:

```bash
terraform -chdir=foundation init
```

O `init` não implanta as aplicações. Preserve e versione `.terraform.lock.hcl`; ele ajuda a manter a mesma versão do provider entre máquinas.

## 4. `fmt` e `validate`: conferir os arquivos

```bash
terraform fmt -check -recursive
```

Verifica se a formatação dos arquivos Terraform está padronizada, incluindo subdiretórios. `-check` apenas verifica; para corrigir a formatação, use `terraform fmt -recursive`.

```bash
terraform validate
terraform -chdir=foundation validate
```

O `validate` verifica a estrutura e a consistência da configuração após o `init`. Na raiz, os cinco templates em `prepared/` precisam estar disponíveis pelo fluxo de adoção ou preparação.

Esses comandos não criam recursos. Uma validação bem-sucedida não confirma permissões AWS, conectividade ou funcionamento das aplicações.

## 5. `plan`: descobrir o que vai mudar

```bash
mkdir -p .local
terraform plan -out=.local/deploy.tfplan
```

O `plan` consulta a situação dos recursos e propõe as mudanças necessárias. `-out` salva a proposta em um arquivo binário para revisão e aplicação posterior. Sem `-out`, o comando exibe uma proposta, mas não salva um plano para aplicar depois. Consulte a [referência oficial de plan](https://developer.hashicorp.com/terraform/cli/commands/plan).

Exemplo ilustrativo de resumo:

```text
Plan: 1 to add, 2 to change, 0 to destroy.
```

Isso significa uma criação, duas alterações e nenhuma destruição no nível dos recursos gerenciados pelo Terraform.

| Símbolo no plano | Significado |
|---|---|
| `+` | Criar |
| `~` | Atualizar |
| `-` | Excluir |
| `-/+` ou `+/-` | Substituir, com exclusão e criação em ordens diferentes |

`No changes` significa que o plano não encontrou mudanças a aplicar. Não comprova que a aplicação está saudável.

**Neste projeto, uma atualização de stack pode alterar ou substituir recursos internos do CloudFormation.** Revise também os templates e parâmetros; o resumo Terraform não detalha integralmente essas mudanças internas.

O plano não executa as mudanças propostas. Porém, o script `plan-foundation.sh`, explicado adiante, pode restaurar secrets e alterar o state antes de gerar seu plano.

## 6. `show`: ler o plano salvo

```bash
terraform show .local/deploy.tfplan
```

Mostra o conteúdo legível do plano binário. Confira os recursos, nomes e mudanças antes de aplicar.

Os caminhos de arquivos também acompanham `-chdir`. Por exemplo:

```bash
terraform -chdir=foundation show foundation.tfplan
```

Esse comando lê `foundation/foundation.tfplan`. Já `terraform -chdir=foundation show ../.local/exemplo.tfplan` leria um plano em `.local/` na raiz.

## 7. `apply`: executar o plano revisado

```bash
terraform apply .local/deploy.tfplan
```

Esse é o passo que altera a infraestrutura AWS. Ao receber um plano salvo, o Terraform o executa **sem pedir uma nova confirmação interativa**. Revise com `show` antes de executar. Consulte a [referência oficial de apply](https://developer.hashicorp.com/terraform/cli/commands/apply).

Também existe `terraform apply` sem arquivo: ele calcula um plano e pede confirmação. O fluxo deste projeto usa planos salvos para permitir revisão explícita.

Se mudar parâmetros, templates ou releases depois de planejar, gere e revise um novo plano. Após uma falha parcial, preserve o state, corrija a causa e planeje novamente.

Nas EC2, concluir o `apply` não substitui a etapa Ansible nem os testes descritos em [EXECUCAO.md](EXECUCAO.md).

## 8. Exemplo: criar a fundação

Após configurar os parâmetros e cumprir os pré-requisitos de [FUNDACAO.md](FUNDACAO.md), execute:

```bash
terraform -chdir=foundation init
terraform -chdir=foundation validate
bash scripts/plan-foundation.sh
terraform -chdir=foundation show foundation.tfplan
```

O script gera `foundation/foundation.tfplan`. Antes disso, consulta os dois secrets previstos: importa os existentes para o state e, se estiverem com exclusão agendada, cancela esse agendamento. Ele não lê seus valores nem aplica o plano. Reutilize apenas secrets deste ambiente que não pertençam a outro state.

Depois de revisar o plano:

```bash
terraform -chdir=foundation apply foundation.tfplan
```

Continue o roteiro da fundação para preencher os secrets, verificar SES e gerar a configuração inicial das aplicações.

## 9. Exemplo: atualizar as aplicações

Para um ambiente já configurado, faça os backups e a pausa do scheduler previstos em [EXECUCAO.md](EXECUCAO.md). A pausa usa os templates e releases atuais, antes de preparar uma nova versão:

```bash
mkdir -p .local
printf '{"scheduler_paused":true}\n' > maintenance.auto.tfvars.json
terraform plan -out=.local/pause.tfplan
terraform show .local/pause.tfplan
```

Aplique somente se o plano corresponder à pausa esperada:

```bash
terraform apply .local/pause.tfplan
bash scripts/check-scheduler.sh
```

A pausa impede novos agendamentos, mas não cancela execuções já entregues. Aguarde as execuções em andamento conforme o roteiro operacional. Depois prepare os artefatos:

```bash
bash scripts/prepare.sh
terraform plan -out=.local/deploy.tfplan
terraform show .local/deploy.tfplan
```

O `prepare.sh` compila e envia artefatos ao S3, gera os arquivos de release e executa `fmt -check` e `validate`. Ele já faz uploads, mas a aplicação das stacks continua sendo uma etapa explícita:

```bash
terraform apply .local/deploy.tfplan
```

Conclua o deploy Ansible e as verificações de [EXECUCAO.md](EXECUCAO.md) antes de liberar o scheduler. `scheduler_paused=false` volta a respeitar `RunBetState` e `CheckDrawsState` configurados; não significa habilitar automaticamente os dois jobs.

## 10. `output`: consultar os resultados

```bash
terraform output -json stack_outputs
terraform output -json scheduler_states
terraform -chdir=foundation output -json configuration
```

Esses comandos leem as saídas gravadas no state: dados das stacks, estados dos agendamentos e configuração da fundação. `-json` fornece um formato que scripts conseguem processar.

O output `scheduler_states` é marcado como sensível, mas `-json` exibe seu conteúdo. Proteja saídas, states e planos: a marcação `sensitive` não criptografa esses arquivos.

## 11. `state list`, `state pull` e `import`: administrar o registro

Para listar os endereços registrados:

```bash
terraform state list
terraform -chdir=foundation state list
```

Na raiz, os endereços das cinco stacks são `aws_cloudformation_stack.mail`, `.gmail`, `.whatsapp`, `.bot` e `.scheduler`. A listagem também pode incluir leituras de dados, como `data.aws_instance.bot`.

Para salvar uma cópia protegida dos dois states:

```bash
umask 077
mkdir -p .local
stamp=$(date -u +%Y%m%dT%H%M%SZ)
terraform state pull > ".local/applications-state-$stamp.json"
terraform -chdir=foundation state pull > ".local/foundation-state-$stamp.json"
```

Execute para states existentes e confira se cada comando terminou com sucesso. Esses backups registram o controle do Terraform; não fazem backup dos dados das EC2 ou tabelas. Restaurar um state antigo não reverte a AWS.

O `import` associa um recurso que já existe a um endereço da configuração. Exemplo para uma stack existente cujo nome foi conferido e exportado em `MAIL_STACK`:

```bash
terraform import aws_cloudformation_stack.mail "$MAIL_STACK"
```

Ele altera o state, mas não gera a configuração nem atualiza a stack. Neste projeto, o caminho inicial de adoção é `bash scripts/adopt.sh`, que captura templates e parâmetros, inicializa o Terraform, importa as cinco stacks e gera `.local/adoption.tfplan`. Use-o somente no cenário de instalação existente descrito em [EXECUCAO.md](EXECUCAO.md). A importação manual serve também para concluir uma adoção interrompida, importando apenas os endereços faltantes.

Não importe individualmente as EC2 e Lambdas internas dessas stacks: elas continuam gerenciadas pelo CloudFormation.

## 12. Comandos de uso específico

| Comando | Quando aparece no projeto |
|---|---|
| `terraform console` | O script da fundação avalia expressões para ler conta, região e prefixo com as variáveis carregadas |
| `terraform init -backend=false` | Inicialização para validação local sem inicializar o backend configurado; não simula o provider AWS |
| `terraform test` | Executado pelo runner em uma cópia temporária com providers simulados |
| `terraform init -migrate-state -backend-config=backend.hcl` | Migração opcional para backend remoto, após configurar o backend conforme `OPERACAO.md` |
| `terraform plan -destroy -out=...` | Gera uma proposta de exclusão, usada na desmontagem |

Para os testes locais, prefira `bash tests/run.sh`, conforme [VALIDACAO.md](VALIDACAO.md). O runner prepara as configurações e os mocks necessários.

A migração de backend exige chaves de state diferentes para raiz e fundação. O bucket de artefatos não se torna um backend automaticamente.

## 13. Exclusão e problemas comuns

`terraform destroy` remove os recursos administrados pelo diretório atual. O fluxo de desmontagem deste projeto usa `plan -destroy`, revisão com `show` e `apply` do plano salvo. Siga [ROLLBACK.md](ROLLBACK.md) integralmente para a ordem de remoção, backups e tratamento das proteções e dos dados.

`prevent_destroy` só bloqueia a exclusão pelo Terraform quando está `true` na configuração. Confira os arquivos efetivos: nesta revisão, `main.tf` e `foundation/main.tf` contêm `prevent_destroy = false`; a fundação também contém `force_destroy = true` no bucket e proteção de exclusão das tabelas desabilitada. Não conte com essas proteções sem verificá-las.

| Situação | Como interpretar e agir |
|---|---|
| `No changes` | Não há mudanças propostas; continue as verificações da aplicação |
| Template de `prepared/` ausente | Complete a preparação ou adoção antes de validar/planejar a raiz |
| Credenciais ausentes ou expiradas | Refaça a autenticação e confira o perfil antes de repetir o plano |
| Erro de conta não permitida | Confira `account_id` e a conta autenticada; o provider restringe a conta de destino |
| Plano salvo desatualizado | Gere e revise outro plano |
| `Instance cannot be destroyed` | Há `prevent_destroy = true` no recurso; em uma desmontagem, siga `ROLLBACK.md` |
| Falha parcial no `apply` | Preserve o state atualizado, corrija a causa e gere outro plano |

Para consultar outras opções, use `terraform <comando> -help` ou a [documentação oficial da CLI](https://developer.hashicorp.com/terraform/cli/commands).
