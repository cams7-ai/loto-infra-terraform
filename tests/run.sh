#!/usr/bin/env bash
# Testes locais com CLIs/provider simulados. Não usa credenciais nem executa deploy.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in terraform python3 jq; do command -v "$tool" >/dev/null; done
terraform fmt -check -recursive
bash -n scripts/*.sh tests/run.sh
python3 -m unittest discover -s tests -v
project=$PWD
fixture=$(mktemp -d /tmp/loto-terraform-test.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
cp ./*.tf .terraform.lock.hcl "$fixture/"
cp -R tests "$fixture/"
# Reutiliza somente os providers instalados; nenhum state/config operacional é copiado.
if [[ -d .terraform ]]; then ln -s "$project/.terraform" "$fixture/.terraform"; fi
mkdir -p "$fixture/prepared"
for app in mail-sender-aws gmail-reader-aws whatsapp-notify loto-bot loto-scheduler-aws; do
  printf '{"Resources":{"Fixture":{"Type":"AWS::CloudFormation::WaitConditionHandle"}}}\n' > "$fixture/prepared/$app.yaml"
done
cd "$fixture"
if [[ ! -d .terraform ]]; then terraform init -backend=false -input=false; fi
terraform validate
# A limpeza dos recursos simulados exige permitir destroy apenas nesta cópia de teste.
# As cinco proteções devem estar presentes no módulo original e não são alteradas nele.
python3 - <<'PYTEST'
from pathlib import Path
p = Path('main.tf')
s = p.read_text()
assert s.count('lifecycle { prevent_destroy = true }') == 5
p.write_text(s.replace('lifecycle { prevent_destroy = true }', 'lifecycle { prevent_destroy = false }'))
PYTEST
terraform test
# Fundação em cópia isolada: planos com mocks, sem templates de aplicações.
mkdir -p "$fixture/foundation"
cp "$project"/foundation/*.tf "$project/foundation/.terraform.lock.hcl" "$fixture/foundation/"
cp -R "$project/foundation/tests" "$fixture/foundation/"
ln -s "$fixture/.terraform" "$fixture/foundation/.terraform"
terraform -chdir="$fixture/foundation" validate
terraform -chdir="$fixture/foundation" test
