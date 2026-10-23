# Instalação das ferramentas

Os comandos de instalação usam Ubuntu 24.04 x86_64 como ambiente de referência. Adapte o gerenciador de pacotes e os binários ao sistema e à arquitetura da máquina de execução. As EC2 não precisam de Terraform, Docker ou Ansible instalados. O playbook requer o bootstrap Ubuntu/Python 3.12 dos templates atuais.

## 1. Utilitários

```bash
sudo apt-get update
sudo apt-get install -y git curl unzip jq openssh-client ca-certificates gnupg python3-venv pipx
pipx ensurepath
```

Abra um novo terminal após `pipx ensurepath`.

## 2. AWS CLI v2

Se `aws --version` já mostrar v2, preserve a instalação. Caso contrário:

```bash
mkdir -p /tmp/loto-tools/aws
cd /tmp/loto-tools/aws
curl -fSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

A [documentação oficial da AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) contém também verificação da assinatura e instalação ARM64. Use o pacote da arquitetura da sua máquina.

Use o perfil já configurado, ou configure SSO se sua conta o disponibiliza:

```bash
aws configure sso --profile <perfil-exemplo>
aws sso login --profile <perfil-exemplo>
export AWS_PROFILE=<perfil-exemplo>
export AWS_REGION=<regiao-aws>
aws sts get-caller-identity --profile $AWS_PROFILE
```

Substitua `<perfil-exemplo>` pelo nome do perfil escolhido e `<regiao-aws>` pela região do ambiente de destino antes de executar os comandos. Use os mesmos valores em [EXECUCAO.md](EXECUCAO.md).

Não grave access keys em arquivos Terraform. O operador precisa ler/importar/atualizar CloudFormation, publicar objetos no bucket e criar/alterar os recursos definidos pelos templates, incluindo PassRole quando aplicável. Na instalação do zero, precisa também criar VPC, subnets, rotas, endpoints, Security Groups, bucket, chave pública EC2, tabelas DynamoDB, identidade SES e secrets. Use uma identidade autorizada para esses recursos; não crie uma política AdministratorAccess apenas para este projeto.

## 3. Terraform

Instale pelo repositório oficial HashiCorp:

```bash
curl -fsSL https://apt.releases.hashicorp.com/gpg -o /tmp/hashicorp.asc
sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg /tmp/hashicorp.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${UBUNTU_CODENAME:-$VERSION_CODENAME} main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform
terraform version
```

Projeto requer Terraform >= 1.10 e < 2, provider AWS 6.x. Após `terraform init`, versione `.terraform.lock.hcl` para fixar a versão e os checksums do provider. Consulte [instalação oficial](https://developer.hashicorp.com/terraform/install).

## 4. Docker

Para build Linux das Lambdas, instale Docker Engine conforme o [guia oficial Ubuntu](https://docs.docker.com/engine/install/ubuntu/). Uma alternativa simples do repositório Ubuntu:

```bash
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Saia e entre novamente na sessão. O grupo docker permite operações equivalentes a root.

```bash
docker version
docker info
docker run --rm hello-world
```

Não execute os scripts do projeto com sudo: eles usam suas credenciais AWS e seu state.

## 5. SAM CLI

Se já houver SAM instalado, confira `sam --version`. Para instalar em x86_64:

```bash
mkdir -p /tmp/loto-tools/sam
cd /tmp/loto-tools/sam
curl -fSL https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip -o sam.zip
unzip sam.zip -d installer
sudo ./installer/install
sam --version
```

Consulte a [instalação oficial SAM](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html) para assinatura e outras arquiteturas. Aqui SAM só executa `build` e `package`. O scheduler também executa seu `scripts/check_artifact.py` em um container do runtime selecionado, sem depender das bibliotecas Python locais. Na instalação do zero, as duas tabelas são criadas pelo Terraform em `foundation/`; seus scripts externos são reservados a instalações que não usam essa fundação.

## 6. Ansible

O Ansible Core 2.19 requer Python 3.11 a 3.13 na máquina local. Se o `pipx` usar Python 3.10, a instalação falhará com `Requires-Python >=3.11` e `No matching distribution found`. Selecione explicitamente Python 3.12, sem substituir o Python do sistema.

Confira se o `uv` está disponível com `uv --version`. Se ainda não estiver instalado, instale-o com `pipx install uv` e abra um novo terminal após executar `pipx ensurepath`.

```bash
uv python install 3.12
pipx install --python "$(uv python find 3.12)" 'ansible-core>=2.19,<2.20'
pipx ensurepath
ansible --version
ansible-playbook --version
```

Na saída de `ansible --version`, confirme Ansible Core 2.19.x e Python 3.12.x. Se o comando não for encontrado após a instalação, abra um novo terminal. Referências: [compatibilidade de Python do Ansible](https://docs.ansible.com/projects/ansible/latest/reference_appendices/release_and_maintenance.html) e [seleção do interpretador no pipx](https://pipx.pypa.io/stable/reference/cli.html).

Somente módulos `ansible.builtin` são utilizados; não é preciso instalar collections AWS. A implantação usa HCL, YAML e Bash; os testes locais também usam Python 3, somente com a biblioteca padrão. Referência: [instalação Ansible](https://docs.ansible.com/projects/ansible/latest/installation_guide/intro_installation.html).

## 7. Conferência final

```bash
terraform version
aws --version
sam --version
ansible --version
docker info
git --version
jq --version
ssh -V
aws sts get-caller-identity --profile $AWS_PROFILE
```

A máquina local precisa de IPv6 funcional para SSH às EC2. Acesso ao navegador via túnel também depende de ela permanecer ligada. Registre as versões utilizadas na primeira release.
