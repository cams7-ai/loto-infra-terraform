# LotoBot — deploy local com Terraform

Projeto dedicado às cinco aplicações existentes: `mail-sender-aws`, `gmail-reader-aws`, `whatsapp-notify`, `loto-bot` e `loto-scheduler-aws`. Sem GitHub Actions.

## Decisão de implementação

Esta primeira versão usa **Terraform + CloudFormation/SAM + Ansible**. Não é uma conversão dos recursos para Terraform nativo: Terraform administra as stacks por `aws_cloudformation_stack`; CloudFormation continua responsável por suas EC2, IAM e Lambdas. Isso permite importar as stacks já implantadas e aproveitar seus templates e verificações.

SAM compila e publica pacotes Lambda, sem executar `sam deploy`. Ansible atualiza o código das EC2 existentes e verifica Nginx/API, porque atualizar UserData não reinstala automaticamente a aplicação. A configuração inicial continua nos templates dos repositórios. O scheduler usa o IP privado atual e o Security Group do bot e o ARN do mail-sender, ligados pelo Terraform. Os parâmetros de rede do scheduler devem apontar para a mesma VPC e subnets com acesso privado ao bot e aos serviços AWS.

| Componente | Responsável |
|---|---|
| Stacks e dependências entre as cinco aplicações | Terraform |
| Recursos dentro de cada stack e bootstrap EC2 | Templates CloudFormation existentes |
| Build Lambda e upload S3 | SAM CLI |
| Atualização do código EC2, troca de release e recuperação | Ansible |
| Rede, endpoints, bucket, chave pública SSH, contêineres dos secrets, SES e tabelas | Terraform separado em `foundation/` para instalação do zero |
| Scheduler | Stack gerenciada pelo Terraform; pausa de manutenção com `scheduler_paused` |
| Tabela de execuções do scheduler | Gerenciada pela fundação, preservada durante deploy e rollback das aplicações |
| Túnel SOCKS | Serviço SSH local, separado do deploy |

**Comece por [INSTALACAO.md](INSTALACAO.md), depois [EXECUCAO.md](EXECUCAO.md).** Consulte [OPERACAO.md](OPERACAO.md) para reversão de versão, state e limitações, e [ROLLBACK.md](ROLLBACK.md) para desmontar completamente o ambiente AWS.

Nenhum comando de deploy roda ao abrir o projeto. A preparação envia artefatos ao S3; `terraform apply` e `ansible-playbook` são etapas explícitas.

## Arquivos

- `*.tf`: provider, cinco stacks e outputs.
- `foundation/`: infraestrutura básica, com state independente das aplicações.
- `FUNDACAO.md`: criação do ambiente vazio e configuração dos secrets/SES.
- `ROLLBACK.md`: desmontagem definitiva das aplicações e da fundação, com tratamento dos dados e recursos restantes.
- `scripts/configure-new.sh`: gera a configuração inicial a partir dos outputs da fundação.
- `scripts/plan-foundation.sh`: restaura/importa secrets existentes antes de planejar a fundação; cria as ausentes no apply.
- `scripts/adopt.sh`: captura configuração atual e importa stacks.
- `scripts/prepare.sh`: build e upload das releases.
- `scripts/inventory.sh`: inventário IPv6 e integridade dos ZIPs.
- `scripts/check.sh`: valida API direta, proxy, comunicação bot → WhatsApp e scheduler.
- `scripts/check-scheduler.sh`: confere Lambda, tabela e estados dos agendamentos sem executar jobs.
- `ansible/deploy.yml`: atualização das EC2 preservando `data/` e `/etc/*.env`.
- `examples/`: parâmetros e serviço local para o túnel.
- `prepared/`: templates reais exportados ou empacotados; gerados localmente.
- `tests/run.sh`: testes locais da integração com CLIs e provider simulados.

O state e os arquivos gerados contêm identificadores e podem conter e-mails/parâmetros sensíveis. `sensitive` esconde a saída normal, mas não criptografa state. Eles estão no `.gitignore`; mantenha backup protegido. Não adicione chaves, tokens OAuth, perfis de navegador ou dados de cartão aos repositórios.
