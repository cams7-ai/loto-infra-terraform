# Guia de validação

Execute as verificações no ambiente de destino com as versões compatíveis descritas em [INSTALACAO.md](INSTALACAO.md) e com o provider fixado em `.terraform.lock.hcl`.

```bash
terraform fmt -check -recursive
bash -n scripts/*.sh
terraform -chdir=foundation init -backend=false
terraform -chdir=foundation validate
ansible-playbook ansible/deploy.yml --syntax-check
```

Após inicializar o Terraform e gerar os cinco templates em `prepared/` pelo fluxo de [EXECUCAO.md](EXECUCAO.md), execute:

```bash
terraform validate
```

Os arquivos em `prepared/` são gerados pela adoção ou preparação, por isso não são distribuídos como templates prontos para aplicar. A validação Terraform não substitui `sam build`, validação CloudFormation, revisão do plano ou testes remotos.

Confira também a integração do scheduler: adoção sem mudanças inesperadas, `MailTo` recuperado sem asteriscos, runtime do build igual ao configurado, validação isolada de imports antes de `sam package`, URL privada/SG do bot e ARN do mail-sender atualizados pelo plano. Antes de aplicar código, confirme a pausa dos dois schedules e a conclusão das execuções pendentes. Após o deploy, `bash scripts/check-scheduler.sh` deve confirmar Lambda ativa, tabela disponível e estados/ timezone esperados sem invocar jobs. Verifique rollback com a pausa mantida, tabela preservada e liberação somente depois da validação das EC2 e do túnel.

## Testes locais da integração

Com Terraform inicializado (`terraform init -backend=false`), Python 3 e jq disponíveis:

```bash
bash tests/run.sh
```

O runner copia apenas a configuração HCL para um diretório temporário, cria templates de fixture e usa CLIs simuladas e `mock_provider` do Terraform. Não copia state, parâmetros ou templates operacionais e não usa credenciais AWS. Os testes Terraform aplicam e removem somente recursos simulados, conforme a [documentação de mocks](https://developer.hashicorp.com/terraform/language/tests/mocking). O runner confere as cinco proteções `prevent_destroy` e as desabilita apenas na cópia temporária para permitir a limpeza dos mocks; a configuração operacional mantém essas proteções. Verifica também a fundação em planos com mocks (rede/endpoints, bucket e schemas das tabelas), geração da configuração inicial, bloqueio de conta/região incorretas e preservação de arquivos existentes. Verifica adoção das cinco stacks, migração das quatro existentes, recuperação de NoEcho, runtime do build, bloqueio de publicação de artefato inválido, detecção de schedules em estado inesperado, pausa/liberação e atualização da URL após troca do IP do bot.

Registre os resultados e as versões das ferramentas na validação de cada release. A presença deste guia não atesta execução de import, plan conectado à AWS, apply, upload S3, conexão SSH ou implantação Ansible no ambiente de destino. Preserve os registros que contêm identificadores ou parâmetros sensíveis fora dos arquivos versionados.

A configuração é híbrida: Terraform administra as stacks CloudFormation existentes. A instalação do zero cria a fundação com HCL nativo em `foundation/`, em um state separado; os recursos internos das aplicações continuam em CloudFormation.

Na instalação nova, confira o plano da fundação antes do apply. Verifique DNS da VPC, atribuição/rota IPv6, ausência de IPv4 público, endpoints disponíveis, bloqueio público/criptografia/versionamento do bucket, chave pública correta, tabelas `ACTIVE` com chaves `bet_id`/`pk` e TTL `expires_at`, versões dos dois secrets e SES `SUCCESS`. Confirme que a configuração gerada usa os outputs dessa fundação, evita endpoints duplicados e mantém pagamentos/agendamentos desativados. Mocks validam a configuração local; conectividade, bootstrap e verificação SES exigem a validação real do roteiro.
