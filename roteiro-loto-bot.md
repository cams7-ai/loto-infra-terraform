# Roteiro de operação do LotoBot na AWS

Comandos para criação, implantação e reversão dos serviços e da infraestrutura do LotoBot na AWS. Execute as etapas na ordem apresentada, substituindo os valores de exemplo pelos dados do seu ambiente.

## Criação

### Mail Sender

```bash
cd "$HOME/projetos/mail-sender-aws"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='mail-sender'
MAIL_FROM=<seu-email-verificado@example.com>

aws sesv2 create-email-identity --email-identity $MAIL_FROM
echo "Verification status: $(aws sesv2 get-email-identity --email-identity "$MAIL_FROM" --query 'VerificationStatus' --output text)"

sam validate --lint
sam build
sam deploy
```

### Gmail Reader

```bash
cd "$HOME/projetos/gmail-reader-aws"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='gmail-reader'
OAUTH_SECRET_NAME='gmail-reader/google-oauth-token'
TOKEN_PATH='file://GmailAPI/token.json'

source .venv/bin/activate
python -m pip install -r src/requirements.txt
python -m pip install -e '.[dev]'
export PYTHONPATH='src'
python -c "from config import Settings; from infra import GmailAuthenticator; GmailAuthenticator(Settings()).authenticate()"

GMAIL_OAUTH_SECRET_ARN=$(aws secretsmanager create-secret --name $OAUTH_SECRET_NAME --secret-string $TOKEN_PATH --query ARN --output text)
[[ -n "$GMAIL_OAUTH_SECRET_ARN" && "$GMAIL_OAUTH_SECRET_ARN" != None && ! "$GMAIL_OAUTH_SECRET_ARN" =~ [[:space:]] ]] || { echo 'GMAIL_OAUTH_SECRET_ARN ausente ou ambíguo' >&2; }

sam validate --lint
sam build
sam deploy --parameter-overrides GmailOAuthSecretArn="$GMAIL_OAUTH_SECRET_ARN" WaitTimeoutSeconds=15
```

### LotoBot — preparação da infraestrutura

```bash
cd "$HOME/projetos/loto-bot"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='loto-bot'
INSTANCE_TYPE='t3.micro'
DYNAMODB_TABLE_NAME="${STACK_NAME}-bets"
KEY_NAME="$STACK_NAME"
KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
KNOWN_HOSTS_FILE="$HOME/.ssh/$KEY_NAME-known-hosts"
OAUTH_SECRET_NAME="$STACK_NAME/application"
APPLICATION_SECRET_PATH='file://application-secret.json'
LOCAL_PUBLIC_IPV6="$(curl -6 -fsS --max-time 20 https://api64.ipify.org)"
[[ -n "$LOCAL_PUBLIC_IPV6" && "$LOCAL_PUBLIC_IPV6" != None && ! "$LOCAL_PUBLIC_IPV6" =~ [[:space:]] ]] || { echo 'LOCAL_PUBLIC_IPV6 ausente ou ambíguo' >&2; }
[[ "$LOCAL_PUBLIC_IPV6" == *:* && "$LOCAL_PUBLIC_IPV6" =~ ^[0-9a-fA-F:]+$ ]] || { echo 'Endereço IPv6 inválido' >&2; }
ALLOWED_SSH_IPV6_CIDR="$LOCAL_PUBLIC_IPV6/128"
AMI_ID="$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)"
[[ -n "$AMI_ID" && "$AMI_ID" != None && ! "$AMI_ID" =~ [[:space:]] ]] || { echo 'AMI_ID ausente ou ambíguo' >&2; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != None && ! "$ACCOUNT_ID" =~ [[:space:]] ]] || { echo 'ACCOUNT_ID ausente ou ambíguo' >&2; }
ARTIFACT_BUCKET="$STACK_NAME-artifacts-$ACCOUNT_ID-$AWS_DEFAULT_REGION"

VPC_IPV4_CIDR='10.77.0.0/16'
SUBNET_IPV4_CIDR='10.77.1.0/24'
VPC_ID="$(aws ec2 create-vpc --cidr-block "$VPC_IPV4_CIDR" --amazon-provided-ipv6-cidr-block --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$STACK_NAME},{Key=Application,Value=$STACK_NAME}]" --query Vpc.VpcId --output text)"
[[ -n "$VPC_ID" && "$VPC_ID" != None && ! "$VPC_ID" =~ [[:space:]] ]] || { echo 'VPC_ID ausente ou ambíguo' >&2; }
aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support Value=true
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames Value=true

VPC_IPV6_CIDR=''
for attempt in {1..30}; do
  VPC_IPV6_CIDR="$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query "Vpcs[0].Ipv6CidrBlockAssociationSet[?Ipv6CidrBlockState.State=='associated'].Ipv6CidrBlock | [0]" --output text)"
  [[ "$VPC_IPV6_CIDR" != "None" && -n "$VPC_IPV6_CIDR" ]] && break
  sleep 2
done
[[ "$VPC_IPV6_CIDR" != "None" && -n "$VPC_IPV6_CIDR" ]] || { echo "IPv6 da VPC indisponível" >&2; return 1 2>/dev/null }
SUBNET_IPV6_CIDR="$(python3 -c 'import ipaddress,sys; print(next(ipaddress.ip_network(sys.argv[1]).subnets(new_prefix=64)))' "$VPC_IPV6_CIDR")"
[[ -n "$SUBNET_IPV6_CIDR" && "$SUBNET_IPV6_CIDR" != None && ! "$SUBNET_IPV6_CIDR" =~ [[:space:]] ]] || { echo 'SUBNET_IPV6_CIDR ausente ou ambíguo' >&2; }

INTERNET_GATEWAY_ID="$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$STACK_NAME}]" --query InternetGateway.InternetGatewayId --output text)"
[[ -n "$INTERNET_GATEWAY_ID" && "$INTERNET_GATEWAY_ID" != None && ! "$INTERNET_GATEWAY_ID" =~ [[:space:]] ]] || { echo 'INTERNET_GATEWAY_ID ausente ou ambíguo' >&2; }
aws ec2 attach-internet-gateway --internet-gateway-id "$INTERNET_GATEWAY_ID" --vpc-id "$VPC_ID"
AVAILABILITY_ZONE="$(aws ec2 describe-availability-zones --filters Name=state,Values=available --query 'AvailabilityZones[0].ZoneName' --output text)"
[[ -n "$AVAILABILITY_ZONE" && "$AVAILABILITY_ZONE" != None && ! "$AVAILABILITY_ZONE" =~ [[:space:]] ]] || { echo 'AVAILABILITY_ZONE ausente ou ambíguo' >&2; }
SUBNET_ID="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_IPV4_CIDR" --ipv6-cidr-block "$SUBNET_IPV6_CIDR" --availability-zone "$AVAILABILITY_ZONE" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$STACK_NAME}]" --query Subnet.SubnetId --output text)"
[[ -n "$SUBNET_ID" && "$SUBNET_ID" != None && ! "$SUBNET_ID" =~ [[:space:]] ]] || { echo 'SUBNET_ID ausente ou ambíguo' >&2; }
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --assign-ipv6-address-on-creation
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --no-map-public-ip-on-launch
ROUTE_TABLE_ID="$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$STACK_NAME}]" --query RouteTable.RouteTableId --output text)"
[[ -n "$ROUTE_TABLE_ID" && "$ROUTE_TABLE_ID" != None && ! "$ROUTE_TABLE_ID" =~ [[:space:]] ]] || { echo "Tabela de rotas ausente ou ambígua" >&2; }
aws ec2 create-route --route-table-id "$ROUTE_TABLE_ID" --destination-ipv6-cidr-block ::/0 --gateway-id "$INTERNET_GATEWAY_ID"
ROUTE_ASSOCIATION_ID="$(aws ec2 associate-route-table --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$SUBNET_ID" --query AssociationId --output text)"
[[ -n "$ROUTE_ASSOCIATION_ID" && "$ROUTE_ASSOCIATION_ID" != None && ! "$ROUTE_ASSOCIATION_ID" =~ [[:space:]] ]] || { echo 'ROUTE_ASSOCIATION_ID ausente ou ambíguo' >&2; }

CFN_GROUP_NAME="$STACK_NAME-cloudformation-endpoint"
CFN_GROUP_ID="$(aws ec2 create-security-group --group-name "$CFN_GROUP_NAME" --description 'Private CloudFormation endpoint for LotoBot EC2 stacks' --vpc-id "$VPC_ID" --query GroupId --output text)"
[[ -n "$CFN_GROUP_ID" && "$CFN_GROUP_ID" != None && ! "$CFN_GROUP_ID" =~ [[:space:]] ]] || { echo 'CFN_GROUP_ID ausente ou ambíguo' >&2; }
aws ec2 authorize-security-group-ingress --group-id "$CFN_GROUP_ID" --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$VPC_IPV4_CIDR}]"
CFN_ENDPOINT_ID="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface --service-name "com.amazonaws.$AWS_DEFAULT_REGION.cloudformation" --subnet-ids "$SUBNET_ID" --security-group-ids "$CFN_GROUP_ID" --private-dns-enabled --query VpcEndpoint.VpcEndpointId --output text)"
[[ -n "$CFN_ENDPOINT_ID" && "$CFN_ENDPOINT_ID" != None && ! "$CFN_ENDPOINT_ID" =~ [[:space:]] ]] || { echo 'CFN_ENDPOINT_ID ausente ou ambíguo' >&2; }
for attempt in {1..60}; do
  endpoint_state="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$CFN_ENDPOINT_ID" --query 'VpcEndpoints[0].State' --output text)"
  [[ "$endpoint_state" == 'available' ]] && break
  [[ "$endpoint_state" == 'failed' ]] && { echo 'Endpoint CloudFormation falhou' >&2; return 1 2>/dev/null }
  sleep 5
done
[[ "$endpoint_state" == 'available' ]] || { echo 'Endpoint CloudFormation indisponível' >&2; return 1 2>/dev/null }
./scripts/test-shared-cloudformation-endpoint.sh --vpc-id "$VPC_ID" --profile $AWS_DEFAULT_PROFILE --region $AWS_DEFAULT_REGION

INTEGRATION_GROUP_ID="$(aws ec2 create-security-group --group-name "$STACK_NAME" --description 'Shared source identity for LotoBot internal integrations' --vpc-id "$VPC_ID" --query GroupId --output text)"
[[ -n "$INTEGRATION_GROUP_ID" && "$INTEGRATION_GROUP_ID" != None && ! "$INTEGRATION_GROUP_ID" =~ [[:space:]] ]] || { echo 'INTEGRATION_GROUP_ID ausente ou ambíguo' >&2; }

[[ ! -e "$KEY_FILE" ]] || { echo "Chave local já existe: $KEY_FILE" >&2; }
umask 077
KEY_TEMP="$(mktemp "${KEY_FILE}.XXXXXX")"
if aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 --key-format pem --query KeyMaterial --output text > "$KEY_TEMP"; then
  [[ -s "$KEY_TEMP" ]] || { echo 'Chave retornada vazia' >&2; }
  chmod 600 "$KEY_TEMP"
  ln "$KEY_TEMP" "$KEY_FILE"
  rm -- "$KEY_TEMP"
else
  rm -- "$KEY_TEMP"
  exit 1
fi

./scripts/create-application-secret.sh "$APPLICATION_SECRET_PATH"
APPLICATION_SECRET_ARN="$(aws secretsmanager create-secret --name "$OAUTH_SECRET_NAME" --secret-string "$APPLICATION_SECRET_PATH" --query ARN --output text)"
[[ -n "$APPLICATION_SECRET_ARN" && "$APPLICATION_SECRET_ARN" != None && ! "$APPLICATION_SECRET_ARN" =~ [[:space:]] ]] || { echo 'APPLICATION_SECRET_ARN ausente ou ambíguo' >&2; }
```

### WhatsApp Notify

```bash
cd "$HOME/projetos/whatsapp-notify"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
BOT_STACK='loto-bot'
STACK_NAME='whatsapp-notify'
INSTANCE_TYPE='t3.micro'
REMOTE_USER='ubuntu'
KEY_NAME="$STACK_NAME"
KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
KNOWN_HOSTS_FILE="$HOME/.ssh/$KEY_NAME-known-hosts"
LOCAL_PUBLIC_IPV6="$(curl -6 -fsS --max-time 20 https://api64.ipify.org)"
[[ -n "$LOCAL_PUBLIC_IPV6" && "$LOCAL_PUBLIC_IPV6" != None && ! "$LOCAL_PUBLIC_IPV6" =~ [[:space:]] ]] || { echo 'LOCAL_PUBLIC_IPV6 ausente ou ambíguo' >&2; }
[[ "$LOCAL_PUBLIC_IPV6" == *:* && "$LOCAL_PUBLIC_IPV6" =~ ^[0-9a-fA-F:]+$ ]] || { echo 'Endereço IPv6 inválido' >&2; }
ALLOWED_SSH_IPV6_CIDR="$LOCAL_PUBLIC_IPV6/128"
AMI_ID="$(aws ssm get-parameter --name '/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id' --query Parameter.Value --output text)"
[[ -n "$AMI_ID" && "$AMI_ID" != None && ! "$AMI_ID" =~ [[:space:]] ]] || { echo 'AMI_ID ausente ou ambíguo' >&2; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != None && ! "$ACCOUNT_ID" =~ [[:space:]] ]] || { echo 'ACCOUNT_ID ausente ou ambíguo' >&2; }
ARTIFACT_BUCKET="$STACK_NAME-artifacts-$ACCOUNT_ID-$AWS_DEFAULT_REGION"
VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$BOT_STACK" "Name=tag:Application,Values=$BOT_STACK" --query 'Vpcs[].VpcId' --output text)"
[[ -n "$VPC_ID" && "$VPC_ID" != None && ! "$VPC_ID" =~ [[:space:]] ]] || { echo 'VPC_ID ausente ou ambíguo' >&2; }
SUBNET_ID="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$BOT_STACK" --query 'Subnets[].SubnetId' --output text)"
[[ -n "$SUBNET_ID" && "$SUBNET_ID" != None && ! "$SUBNET_ID" =~ [[:space:]] ]] || { echo 'SUBNET_ID ausente ou ambíguo' >&2; }

[[ ! -e "$KEY_FILE" ]] || { echo "Chave local já existe: $KEY_FILE" >&2; }
umask 077
KEY_TEMP="$(mktemp "${KEY_FILE}.XXXXXX")"
if aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 --key-format pem --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$KEY_NAME},{Key=Application,Value=$BOT_STACK}]" --query KeyMaterial --output text > "$KEY_TEMP"; then
  [[ -s "$KEY_TEMP" ]] || { echo 'Chave retornada vazia' >&2; }
  chmod 600 "$KEY_TEMP"
  ln "$KEY_TEMP" "$KEY_FILE"
  rm -- "$KEY_TEMP"
else
  rm -- "$KEY_TEMP"
  exit 1
fi

SECURITY_GROUP_ID="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$BOT_STACK" --query 'SecurityGroups[].GroupId' --output text)"
[[ -n "$SECURITY_GROUP_ID" && "$SECURITY_GROUP_ID" != None && ! "$SECURITY_GROUP_ID" =~ [[:space:]] ]] || { echo 'SECURITY_GROUP_ID ausente ou ambíguo' >&2; }

aws s3api create-bucket --bucket "$ARTIFACT_BUCKET"
aws s3api put-public-access-block --bucket "$ARTIFACT_BUCKET" --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
aws s3api put-bucket-encryption --bucket "$ARTIFACT_BUCKET" --server-side-encryption-configuration 'Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]'

ARTIFACT_VERSION="$(date -u +%Y%m%d-%H%M%S)"
[[ -n "$ARTIFACT_VERSION" && "$ARTIFACT_VERSION" != None && ! "$ARTIFACT_VERSION" =~ [[:space:]] ]] || { echo 'ARTIFACT_VERSION ausente ou ambíguo' >&2; }
ARTIFACT_KEY="$STACK_NAME/releases/$ARTIFACT_VERSION/$STACK_NAME.zip"
ARTIFACT_FILE="$(mktemp --suffix=.zip)"
[[ -n "$ARTIFACT_FILE" && "$ARTIFACT_FILE" != None && ! "$ARTIFACT_FILE" =~ [[:space:]] ]] || { echo 'ARTIFACT_FILE ausente ou ambíguo' >&2; }
rm -f "$ARTIFACT_FILE"
zip -q -r "$ARTIFACT_FILE" pyproject.toml README.md src
unzip -l "$ARTIFACT_FILE"
ARTIFACT_SHA256="$(sha256sum "$ARTIFACT_FILE" | cut -d ' ' -f 1)"
[[ -n "$ARTIFACT_SHA256" && "$ARTIFACT_SHA256" != None && ! "$ARTIFACT_SHA256" =~ [[:space:]] ]] || { echo 'ARTIFACT_SHA256 ausente ou ambíguo' >&2; }
aws s3 cp "$ARTIFACT_FILE" "s3://$ARTIFACT_BUCKET/$ARTIFACT_KEY" --sse AES256 --metadata "sha256=$ARTIFACT_SHA256"
aws s3api head-object --bucket "$ARTIFACT_BUCKET" --key "$ARTIFACT_KEY"

sam validate --lint --template-file template.yaml
sam build --template-file template.yaml
sam deploy --template-file template.yaml \
  --parameter-overrides \
    "VpcId=$VPC_ID" "SubnetId=$SUBNET_ID" "AmiId=$AMI_ID" \
    "InstanceType=$INSTANCE_TYPE" "KeyName=$KEY_NAME" \
    "AllowedSshIpv6Cidr=$ALLOWED_SSH_IPV6_CIDR" \
    "IntegrationSecurityGroupId=$SECURITY_GROUP_ID" \
    "ArtifactBucket=$ARTIFACT_BUCKET" "ArtifactKey=$ARTIFACT_KEY" \
    "ArtifactSha256=$ARTIFACT_SHA256" RootVolumeSize=16
    
INSTANCE_ID="$(aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" --logical-resource-id ApplicationInstance --query StackResourceDetail.PhysicalResourceId --output text)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != None && ! "$INSTANCE_ID" =~ [[:space:]] ]] || { echo 'INSTANCE_ID ausente ou ambíguo' >&2; }
INSTANCE_IPV6="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' --output text)"
[[ -n "$INSTANCE_IPV6" && "$INSTANCE_IPV6" != None && ! "$INSTANCE_IPV6" =~ [[:space:]] ]] || { echo 'INSTANCE_IPV6 ausente ou ambíguo' >&2; }
SSH_OPTS=(-i "$KEY_FILE" -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE")

ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" "curl --fail --max-time 30 -i -sSL 'http://127.0.0.1/whatsapp/session/status'"
```

### LotoBot — implantação

```bash
cd "$HOME/projetos/loto-bot"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='loto-bot'
REMOTE_USER='ubuntu'
INSTANCE_TYPE='t3.micro'
DYNAMODB_TABLE_NAME='loto-bot-bets'
KEY_NAME="$STACK_NAME"
KEY_FILE="$HOME/.ssh/$KEY_NAME.pem"
KNOWN_HOSTS_FILE="$HOME/.ssh/$KEY_NAME-known-hosts"
OAUTH_SECRET_NAME="$STACK_NAME/application"
APPLICATION_SECRET_PATH='file://application-secret.json'
LOCAL_PUBLIC_IPV6="$(curl -6 -fsS --max-time 20 https://api64.ipify.org)"
[[ -n "$LOCAL_PUBLIC_IPV6" && "$LOCAL_PUBLIC_IPV6" != None && ! "$LOCAL_PUBLIC_IPV6" =~ [[:space:]] ]] || { echo 'LOCAL_PUBLIC_IPV6 ausente ou ambíguo' >&2; }
[[ "$LOCAL_PUBLIC_IPV6" == *:* && "$LOCAL_PUBLIC_IPV6" =~ ^[0-9a-fA-F:]+$ ]] || { echo 'Endereço IPv6 inválido' >&2; }
ALLOWED_SSH_IPV6_CIDR="$LOCAL_PUBLIC_IPV6/128"
AMI_ID="$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)"
[[ -n "$AMI_ID" && "$AMI_ID" != None && ! "$AMI_ID" =~ [[:space:]] ]] || { echo 'AMI_ID ausente ou ambíguo' >&2; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != None && ! "$ACCOUNT_ID" =~ [[:space:]] ]] || { echo 'ACCOUNT_ID ausente ou ambíguo' >&2; }
ARTIFACT_BUCKET="$STACK_NAME-artifacts-$ACCOUNT_ID-$AWS_DEFAULT_REGION"
VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$STACK_NAME" "Name=tag:Application,Values=$STACK_NAME" --query 'Vpcs[].VpcId' --output text)"
[[ -n "$VPC_ID" && "$VPC_ID" != None && ! "$VPC_ID" =~ [[:space:]] ]] || { echo 'VPC_ID ausente ou ambíguo' >&2; }
SUBNET_ID="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$STACK_NAME" --query 'Subnets[].SubnetId' --output text)"
[[ -n "$SUBNET_ID" && "$SUBNET_ID" != None && ! "$SUBNET_ID" =~ [[:space:]] ]] || { echo 'SUBNET_ID ausente ou ambíguo' >&2; }
SECURITY_GROUP_ID="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$STACK_NAME" --query 'SecurityGroups[].GroupId' --output text)"
[[ -n "$SECURITY_GROUP_ID" && "$SECURITY_GROUP_ID" != None && ! "$SECURITY_GROUP_ID" =~ [[:space:]] ]] || { echo 'SECURITY_GROUP_ID ausente ou ambíguo' >&2; }

APPLICATION_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id $OAUTH_SECRET_NAME --query ARN --output text)
[[ -n "$APPLICATION_SECRET_ARN" && "$APPLICATION_SECRET_ARN" != None && ! "$APPLICATION_SECRET_ARN" =~ [[:space:]] ]] || { echo 'APPLICATION_SECRET_ARN ausente ou ambíguo' >&2; }
GMAIL_READER_FUNCTION_ARN="$(aws cloudformation describe-stacks --stack-name gmail-reader --query "Stacks[0].Outputs[?OutputKey=='FunctionArn'].OutputValue | [0]" --output text)"
[[ -n "$GMAIL_READER_FUNCTION_ARN" && "$GMAIL_READER_FUNCTION_ARN" != None && ! "$GMAIL_READER_FUNCTION_ARN" =~ [[:space:]] ]] || { echo 'GMAIL_READER_FUNCTION_ARN ausente ou ambíguo' >&2; }
MAIL_SENDER_FUNCTION_ARN="$(aws cloudformation describe-stacks --stack-name mail-sender --query "Stacks[0].Outputs[?OutputKey=='FunctionArn'].OutputValue | [0]" --output text)"
[[ -n "$MAIL_SENDER_FUNCTION_ARN" && "$MAIL_SENDER_FUNCTION_ARN" != None && ! "$MAIL_SENDER_FUNCTION_ARN" =~ [[:space:]] ]] || { echo 'MAIL_SENDER_FUNCTION_ARN ausente ou ambíguo' >&2; }
WHATSAPP_NOTIFY_URL="$(aws cloudformation describe-stacks --stack-name whatsapp-notify --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue | [0]" --output text)"
[[ -n "$WHATSAPP_NOTIFY_URL" && "$WHATSAPP_NOTIFY_URL" != None && ! "$WHATSAPP_NOTIFY_URL" =~ [[:space:]] ]] || { echo 'WHATSAPP_NOTIFY_URL ausente ou ambíguo' >&2; }

aws s3api create-bucket --bucket "$ARTIFACT_BUCKET"
aws s3api put-public-access-block --bucket "$ARTIFACT_BUCKET" --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
aws s3api put-bucket-encryption --bucket "$ARTIFACT_BUCKET" --server-side-encryption-configuration 'Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]'

ARTIFACT_VERSION="$(date -u +%Y%m%d-%H%M%S)"
[[ -n "$ARTIFACT_VERSION" && "$ARTIFACT_VERSION" != None && ! "$ARTIFACT_VERSION" =~ [[:space:]] ]] || { echo 'ARTIFACT_VERSION ausente ou ambíguo' >&2; }
ARTIFACT_KEY="$STACK_NAME/releases/$ARTIFACT_VERSION/$STACK_NAME.zip"
ARTIFACT_FILE="$(mktemp --suffix=.zip)"
[[ -n "$ARTIFACT_FILE" && "$ARTIFACT_FILE" != None && ! "$ARTIFACT_FILE" =~ [[:space:]] ]] || { echo 'ARTIFACT_FILE ausente ou ambíguo' >&2; }
rm -f "$ARTIFACT_FILE"
zip -q -r "$ARTIFACT_FILE" pyproject.toml README.md src
unzip -l "$ARTIFACT_FILE"
ARTIFACT_SHA256="$(sha256sum "$ARTIFACT_FILE" | cut -d' ' -f1)"
[[ -n "$ARTIFACT_SHA256" && "$ARTIFACT_SHA256" != None && ! "$ARTIFACT_SHA256" =~ [[:space:]] ]] || { echo 'ARTIFACT_SHA256 ausente ou ambíguo' >&2; }
aws s3 cp "$ARTIFACT_FILE" "s3://$ARTIFACT_BUCKET/$ARTIFACT_KEY" --sse AES256 --metadata "sha256=$ARTIFACT_SHA256"

./scripts/create-dynamodb-aws.sh --profile "$AWS_DEFAULT_PROFILE" --region "$AWS_DEFAULT_REGION" --table "$DYNAMODB_TABLE_NAME"
./scripts/test-shared-cloudformation-endpoint.sh --profile "$AWS_DEFAULT_PROFILE" --region "$AWS_DEFAULT_REGION" --vpc-id "$VPC_ID"

sam validate --lint --template-file template.yaml
sam build --template-file template.yaml
sam deploy --template-file template.yaml --parameter-overrides \
  "VpcId=$VPC_ID" "SubnetId=$SUBNET_ID" "AmiId=$AMI_ID" "InstanceType=$INSTANCE_TYPE" UseLambdaVpcEndpoint=true \
  "KeyName=$KEY_NAME" "AllowedSshIpv6Cidr=$ALLOWED_SSH_IPV6_CIDR" \
  "ArtifactBucket=$ARTIFACT_BUCKET" "ArtifactKey=$ARTIFACT_KEY" "ArtifactSha256=$ARTIFACT_SHA256" \
  "ApplicationSecretArn=$APPLICATION_SECRET_ARN" "GmailReaderFunctionArn=$GMAIL_READER_FUNCTION_ARN" \
  "MailSenderFunctionArn=$MAIL_SENDER_FUNCTION_ARN" "WhatsAppNotifyUrl=$WHATSAPP_NOTIFY_URL" \
  "IntegrationSecurityGroupId=$SECURITY_GROUP_ID" ConfirmPayment=true \
  "DynamoDbTableName=$DYNAMODB_TABLE_NAME" RootVolumeSize=20
  
INSTANCE_ID="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" --output text)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != None && ! "$INSTANCE_ID" =~ [[:space:]] ]] || { echo 'INSTANCE_ID ausente ou ambíguo' >&2; }
INSTANCE_IPV6="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Ipv6Addresses[0].Ipv6Address' --output text)"
[[ -n "$INSTANCE_IPV6" && "$INSTANCE_IPV6" != None && ! "$INSTANCE_IPV6" =~ [[:space:]] ]] || { echo 'INSTANCE_IPV6 ausente ou ambíguo' >&2; }
SSH_OPTS=(-i "$KEY_FILE" -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE")
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" 'curl --fail --max-time 30 -i -sSL http://127.0.0.1/api/v1/sessions/status'

# Túnel em segundo plano; mantenha o computador local ligado e conectado.
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" "sudo fuser -k 1080/tcp >/dev/null 2>&1 || true"
TUNNEL_SOCKET="$HOME/.ssh/loto-bot-control.sock"
[[ ! -e "$TUNNEL_SOCKET" ]] || { echo "Socket já existe; confira o túnel antes de iniciar outro" >&2; }
ssh "${SSH_OPTS[@]}" -f -N -T -M -S "$TUNNEL_SOCKET" -o ControlPersist=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:1080 "$REMOTE_USER@$INSTANCE_IPV6"
ssh -S "$TUNNEL_SOCKET" -O check "$REMOTE_USER@$INSTANCE_IPV6"

ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" 'curl -fsS --max-time 20 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org'
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$INSTANCE_IPV6" 'curl -fsS -L --max-time 20 --socks5-hostname 127.0.0.1:1080 -o /dev/null -w "HTTP %{http_code}\n" "https://www.loteriasonline.caixa.gov.br/silce-web/#/termos-de-uso"'
```

### Loto Scheduler

```bash
cd "$HOME/projetos/loto-scheduler-aws"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='loto-scheduler-aws'
BOT_STACK='loto-bot'
MAIL_STACK='mail-sender'

INSTANCE_ID="$(aws cloudformation describe-stacks --stack-name "$BOT_STACK" --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" --output text)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != None && ! "$INSTANCE_ID" =~ [[:space:]] ]] || { echo 'INSTANCE_ID ausente ou ambíguo' >&2; }
BOT_SG="$(aws cloudformation describe-stacks --stack-name "$BOT_STACK" --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupId'].OutputValue | [0]" --output text)"
[[ -n "$BOT_SG" && "$BOT_SG" != None && ! "$BOT_SG" =~ [[:space:]] ]] || { echo 'BOT_SG ausente ou ambíguo' >&2; }
MAIL_ARN="$(aws cloudformation describe-stacks --stack-name "$MAIL_STACK" --query "Stacks[0].Outputs[?OutputKey=='FunctionArn'].OutputValue | [0]" --output text)"
[[ -n "$MAIL_ARN" && "$MAIL_ARN" != None && ! "$MAIL_ARN" =~ [[:space:]] ]] || { echo 'MAIL_ARN ausente ou ambíguo' >&2; }
VPC_ID="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].VpcId' --output text)"
[[ -n "$VPC_ID" && "$VPC_ID" != None && ! "$VPC_ID" =~ [[:space:]] ]] || { echo 'VPC_ID ausente ou ambíguo' >&2; }
SUBNET_ID="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].SubnetId' --output text)"
[[ -n "$SUBNET_ID" && "$SUBNET_ID" != None && ! "$SUBNET_ID" =~ [[:space:]] ]] || { echo 'SUBNET_ID ausente ou ambíguo' >&2; }
BOT_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
[[ -n "$BOT_IP" && "$BOT_IP" != None && ! "$BOT_IP" =~ [[:space:]] ]] || { echo 'BOT_IP ausente ou ambíguo' >&2; }
BOT_URL="http://$BOT_IP:80"

for value in "$INSTANCE_ID" "$BOT_SG" "$MAIL_ARN" "$VPC_ID" "$SUBNET_ID" "$BOT_IP"; do
  [[ -n "$value" && "$value" != None ]] || { echo 'Output ausente'; }
done

ROUTE_TABLE_ID="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET_ID" --query 'RouteTables[].RouteTableId' --output text)"
if [[ -z "$ROUTE_TABLE_ID" || "$ROUTE_TABLE_ID" == None ]]; then
  ROUTE_TABLE_ID="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" Name=association.main,Values=true --query 'RouteTables[].RouteTableId' --output text)"
fi
LAMBDA_ENDPOINT_SG="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$AWS_DEFAULT_REGION.lambda" --query 'VpcEndpoints[].Groups[].GroupId' --output text)"
[[ -n "$LAMBDA_ENDPOINT_SG" && "$LAMBDA_ENDPOINT_SG" != None && ! "$LAMBDA_ENDPOINT_SG" =~ [[:space:]] ]] || { echo 'LAMBDA_ENDPOINT_SG ausente ou ambíguo' >&2; }

[[ -n "$ROUTE_TABLE_ID" && "$ROUTE_TABLE_ID" != None && ! "$ROUTE_TABLE_ID" =~ [[:space:]] ]] || { echo "Tabela de rotas ausente ou ambígua" >&2; }
DYNAMO_ENDPOINT_COUNT="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$AWS_DEFAULT_REGION.dynamodb" --query 'length(VpcEndpoints)' --output text)"
[[ "$DYNAMO_ENDPOINT_COUNT" =~ ^[0-9]+$ ]] || { echo "Contagem de endpoints inválida" >&2; }
CREATE_DYNAMO_GATEWAY=false
if [[ "$DYNAMO_ENDPOINT_COUNT" == 0 ]]; then
  CREATE_DYNAMO_GATEWAY=true
fi

RUN_CRON="$(.venv/bin/python scripts/convert_cron.py '30 10 * * 1,3,5')" 
CHECK_CRON="$(.venv/bin/python scripts/convert_cron.py '50 10 * * 1,3,5')" 

[[ "$RUN_CRON" == cron\(*\) && "$CHECK_CRON" == cron\(*\) ]] || { echo 'Expressão cron inválida' >&2; }
make lint test validate build artifact

TABLE_NAME='loto-scheduler-executions'
./scripts/create-dynamodb-aws.sh --profile "$AWS_DEFAULT_PROFILE" --region "$AWS_DEFAULT_REGION" --table "$TABLE_NAME"

MAIL_TO=<seu-email-verificado@example.com>
PARAMETERS=(
  "VpcId=$VPC_ID" "SubnetIds=$SUBNET_ID" "LotoBotSecurityGroupId=$BOT_SG"
  "LotoBotUrl=$BOT_URL" LotoBotPort=80 "MailSenderArn=$MAIL_ARN" "MailTo=$MAIL_TO"
  "DynamoDbTableName=$TABLE_NAME"
  "LambdaEndpointSecurityGroupId=$LAMBDA_ENDPOINT_SG"
  "CreateDynamoGateway=$CREATE_DYNAMO_GATEWAY" "RouteTableIds=$ROUTE_TABLE_ID"
  UseIpv6=false UseDualstackLambda=false Runtime=python3.12 Memory=256 Timeout=900
  ReserveConcurrency=false
  RunBetState=ENABLED CheckDrawsState=ENABLED
  "RunBetCron=\"$RUN_CRON\"" "CheckDrawsCron=\"$CHECK_CRON\""
  RunModality=MEGA_SENA CheckModality=ALL LookbackDays=7
  StartSeconds=180 PostSeconds=120 BusySeconds=300 RetentionDays=90
  JobMaxAttempts=3 JobRetryDelaySeconds=30 SessionStartMaxAttempts=3 SessionStartRetryDelaySeconds=15
)
.venv/bin/python scripts/deploy.py --stack-name "$STACK_NAME" --profile "$AWS_DEFAULT_PROFILE" --region "$AWS_DEFAULT_REGION" --parameter-overrides "${PARAMETERS[@]}"
```

## Reversão

### Loto Scheduler

```bash
# Remova primeiro o agendador, depois seus serviços e por último a rede.
# Exclusão definitiva de dados/segredos; arquivos locais são preservados.

cd "$HOME/projetos/loto-scheduler-aws"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='loto-scheduler-aws'
TABLE_NAME='loto-scheduler-executions'

aws cloudformation delete-stack --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

./scripts/delete-dynamodb-aws.sh --profile "$AWS_DEFAULT_PROFILE" --region "$AWS_DEFAULT_REGION" --table "$TABLE_NAME" --force
```

### LotoBot

```bash
cd "$HOME/projetos/loto-bot"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='loto-bot'
DYNAMODB_TABLE_NAME='loto-bot-bets'
KEY_NAME="$STACK_NAME"
OAUTH_SECRET_NAME="$STACK_NAME/application"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ARTIFACT_BUCKET="$STACK_NAME-artifacts-$ACCOUNT_ID-$AWS_DEFAULT_REGION"

# Encerra apenas o túnel criado com o socket deste roteiro.
TUNNEL_SOCKET="$HOME/.ssh/loto-bot-control.sock"
if [[ -S "$TUNNEL_SOCKET" ]]; then
  ssh -S "$TUNNEL_SOCKET" -O check ubuntu@loto-bot
  ssh -S "$TUNNEL_SOCKET" -O exit ubuntu@loto-bot
fi

aws cloudformation delete-stack --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

./scripts/delete-dynamodb-aws.sh --profile "$AWS_DEFAULT_PROFILE" --region "$AWS_DEFAULT_REGION" --table "$DYNAMODB_TABLE_NAME" --force

aws secretsmanager delete-secret --secret-id "$OAUTH_SECRET_NAME" --force-delete-without-recovery

aws ec2 delete-key-pair --key-name "$KEY_NAME"
```

### WhatsApp Notify

```bash
cd "$HOME/projetos/whatsapp-notify"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='whatsapp-notify'
KEY_NAME="$STACK_NAME"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ARTIFACT_BUCKET="$STACK_NAME-artifacts-$ACCOUNT_ID-$AWS_DEFAULT_REGION"

aws cloudformation delete-stack --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

aws ec2 delete-key-pair --key-name "$KEY_NAME"
```

### Gmail Reader

```bash
cd "$HOME/projetos/gmail-reader-aws"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='gmail-reader'
OAUTH_SECRET_NAME='gmail-reader/google-oauth-token'

aws cloudformation delete-stack --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

aws secretsmanager delete-secret --secret-id "$OAUTH_SECRET_NAME" --force-delete-without-recovery
```

### Mail Sender

```bash
cd "$HOME/projetos/mail-sender-aws"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='mail-sender'
MAIL_FROM=<seu-email-verificado@example.com>

aws cloudformation delete-stack --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

aws sesv2 delete-email-identity --email-identity "$MAIL_FROM"
```

### Remoção dos artefatos

```bash
cd "$HOME/projetos"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo 'Conta AWS inválida' >&2; }
OWNED_BUCKETS="$(aws s3api list-buckets --output json)"

# Apenas os buckets exclusivos criados neste roteiro.
# A stack/bucket compartilhados aws-sam-cli-managed-default são preservados.
# Artefatos legados nesses buckets exigem identificação antes de exclusão.
for BUCKET_PREFIX in loto-bot-artifacts whatsapp-notify-artifacts; do
  ARTIFACT_BUCKET="$BUCKET_PREFIX-$ACCOUNT_ID-$AWS_DEFAULT_REGION"
  if ! jq -e --arg bucket "$ARTIFACT_BUCKET" '.Buckets | any(.Name == $bucket)' <<< "$OWNED_BUCKETS" >/dev/null; then
    echo "Bucket ausente: $ARTIFACT_BUCKET"
    continue
  fi
  aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID"
  while true; do
    UPLOADS="$(aws s3api list-multipart-uploads --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --no-paginate --max-uploads 1000 --output json)"
    [[ "$(jq '.Uploads // [] | length' <<< "$UPLOADS")" != 0 ]] || break
    while IFS= read -r UPLOAD; do
      UPLOAD_KEY="$(jq -r '.Key' <<< "$UPLOAD")"
      UPLOAD_ID="$(jq -r '.UploadId' <<< "$UPLOAD")"
      aws s3api abort-multipart-upload --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --key "$UPLOAD_KEY" --upload-id "$UPLOAD_ID"
    done <<< "$(jq -c '.Uploads[]' <<< "$UPLOADS")"
  done

  # Remove todas as versões e marcadores, em lotes de no máximo 1.000 objetos.
  while true; do
    VERSIONS="$(aws s3api list-object-versions --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --no-paginate --max-keys 1000 --output json)"
    DELETE_BATCH="$(jq '{Objects: ([ (.Versions // [])[], (.DeleteMarkers // [])[] ] | map({Key,VersionId})), Quiet: true}' <<< "$VERSIONS")"
    [[ "$(jq '.Objects | length' <<< "$DELETE_BATCH")" != 0 ]] || break
    DELETE_RESULT="$(aws s3api delete-objects --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --delete "$DELETE_BATCH" --output json)"
    jq -e '(.Errors // [] | length) == 0' <<< "$DELETE_RESULT" >/dev/null || { echo "$DELETE_RESULT" >&2; }
  done
  aws s3 rm "s3://$ARTIFACT_BUCKET" --recursive --only-show-errors
  OBJECT_COUNT="$(aws s3api list-objects-v2 --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --max-keys 1 --no-paginate --query KeyCount --output text)"
  [[ "$OBJECT_COUNT" == 0 ]] || { echo "Bucket ainda contém objetos: $ARTIFACT_BUCKET" >&2; }
  aws s3api delete-bucket --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID"
  aws s3api wait bucket-not-exists --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID"
done
```

### Remoção da rede compartilhada

```bash
cd "$HOME/projetos/loto-bot"
export AWS_DEFAULT_PROFILE=<perfil-exemplo>
export AWS_DEFAULT_REGION=<regiao-aws>
STACK_NAME='loto-bot'
VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$STACK_NAME" "Name=tag:Application,Values=$STACK_NAME" --query 'Vpcs[].VpcId' --output text)"
[[ -n "$VPC_ID" && "$VPC_ID" != None && ! "$VPC_ID" =~ [[:space:]] ]] || { echo 'VPC ausente ou ambígua; confira a rede' >&2; }

# As stacks devem estar excluídas; não remover recursos inesperados de outras aplicações.
SUBNETS="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --output json)"
jq -e '(.Subnets | length) <= 1 and all(.Subnets[]; .CidrBlock == "10.77.1.0/24" and any(.Tags[]?; .Key == "Name" and .Value == "loto-bot"))' <<< "$SUBNETS" >/dev/null || { echo 'Subnets não previstas' >&2; }
GROUPS_JSON="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --output json)"
jq -e 'all(.SecurityGroups[]; .GroupName == "default" or .GroupName == "loto-bot" or .GroupName == "loto-bot-cloudformation-endpoint")' <<< "$GROUPS_JSON" >/dev/null || { echo 'Security groups não previstos' >&2; }
ROUTES="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json)"
jq -e 'all(.RouteTables[]; any(.Associations[]?; .Main == true) or any(.Tags[]?; .Key == "Name" and .Value == "loto-bot"))' <<< "$ROUTES" >/dev/null || { echo 'Tabelas de rotas não previstas' >&2; }
GATEWAYS="$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --output json)"
jq -e 'all(.InternetGateways[]; any(.Tags[]?; .Key == "Name" and .Value == "loto-bot"))' <<< "$GATEWAYS" >/dev/null || { echo 'Gateways não previstos' >&2; }
ENDPOINTS="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --output json)"
jq -e --arg service "com.amazonaws.$AWS_DEFAULT_REGION.cloudformation" 'all(.VpcEndpoints[]; .ServiceName == $service)' <<< "$ENDPOINTS" >/dev/null || { echo 'Endpoints de outras stacks ainda presentes' >&2; }

for ENDPOINT_ID in $(jq -r '.VpcEndpoints[] | select(.State != "deleted" and .State != "deleting") | .VpcEndpointId' <<< "$ENDPOINTS"); do
  DELETE_RESULT="$(aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ENDPOINT_ID" --output json)"
  jq -e '(.Unsuccessful // [] | length) == 0' <<< "$DELETE_RESULT" >/dev/null || { echo "$DELETE_RESULT" >&2; }
done

# Aguarda liberação de endpoints e ENIs gerenciadas por Lambda/PrivateLink.
for attempt in {1..240}; do
  ENDPOINT_COUNT="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "length(VpcEndpoints[?State!='deleted'])" --output text)"
  ENI_COUNT="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query 'length(NetworkInterfaces)' --output text)"
  [[ "$ENDPOINT_COUNT" =~ ^[0-9]+$ && "$ENI_COUNT" =~ ^[0-9]+$ ]] || { echo 'Contagem de recursos inválida' >&2; }
  [[ "$ENDPOINT_COUNT" == 0 && "$ENI_COUNT" == 0 ]] && break
  sleep 5
done
[[ "$ENDPOINT_COUNT" == 0 && "$ENI_COUNT" == 0 ]] || { echo 'Endpoints/ENIs ainda presentes; verifique dependências' >&2; }

for ASSOCIATION_ID in $(jq -r '.RouteTables[].Associations[]? | select(.Main != true) | .RouteTableAssociationId' <<< "$ROUTES"); do
  aws ec2 disassociate-route-table --association-id "$ASSOCIATION_ID"
done
for ROUTE_TABLE_ID in $(jq -r '.RouteTables[] | select(any(.Associations[]?; .Main == true) | not) | .RouteTableId' <<< "$ROUTES"); do
  aws ec2 delete-route-table --route-table-id "$ROUTE_TABLE_ID"
done
for SUBNET_ID in $(jq -r '.Subnets[].SubnetId' <<< "$SUBNETS"); do
  aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
done
for SECURITY_GROUP_ID in $(jq -r '.SecurityGroups[] | select(.GroupName != "default") | .GroupId' <<< "$GROUPS_JSON"); do
  aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID"
done
for INTERNET_GATEWAY_ID in $(jq -r '.InternetGateways[].InternetGatewayId' <<< "$GATEWAYS"); do
  aws ec2 detach-internet-gateway --internet-gateway-id "$INTERNET_GATEWAY_ID" --vpc-id "$VPC_ID"
  aws ec2 delete-internet-gateway --internet-gateway-id "$INTERNET_GATEWAY_ID"
done

# Grupo, ACL e tabela de rotas padrão são removidos com a VPC.
aws ec2 delete-vpc --vpc-id "$VPC_ID"
REMAINING_VPCS="$(aws ec2 describe-vpcs --filters "Name=vpc-id,Values=$VPC_ID" --query 'length(Vpcs)' --output text)"
[[ "$REMAINING_VPCS" == 0 ]] || { echo 'VPC ainda presente' >&2; }
```
