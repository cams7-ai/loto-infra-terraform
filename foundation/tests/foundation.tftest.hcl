# Plan somente, sem credenciais e sem criar recursos AWS.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
}
variables {
  account_id          = "123456789012"
  name                = "fresh"
  ssh_public_key_path = "tests/fixture.pub"
  ssh_ipv6_cidr       = "2001:db8::1/128"
  ses_from            = "sender@example.com"
}
run "new_foundation_without_applications" {
  command = plan
  assert {
    condition = (
      aws_vpc.main.enable_dns_support && aws_vpc.main.enable_dns_hostnames &&
      aws_vpc.main.assign_generated_ipv6_cidr_block &&
      aws_subnet.main.assign_ipv6_address_on_creation && !aws_subnet.main.map_public_ip_on_launch &&
      aws_route.internet_ipv6.destination_ipv6_cidr_block == "::/0"
    )
    error_message = "A rede deve permitir IPv6 e DNS, sem IPv4 público."
  }
  assert {
    condition = (
      length(aws_vpc_endpoint.interface) == 3 && length(aws_vpc_endpoint.gateway) == 2 &&
      aws_vpc_endpoint.interface["lambda"].private_dns_enabled &&
      aws_vpc_endpoint.interface["secretsmanager"].vpc_endpoint_type == "Interface" &&
      aws_vpc_endpoint.interface["cloudformation"].private_dns_enabled &&
      aws_vpc_endpoint.gateway["s3"].vpc_endpoint_type == "Gateway" &&
      aws_vpc_endpoint.gateway["dynamodb"].vpc_endpoint_type == "Gateway" &&
      aws_vpc_security_group_ingress_rule.endpoints_https.cidr_ipv4 == "10.77.0.0/16" &&
      aws_vpc_security_group_ingress_rule.endpoints_https.from_port == 443
    )
    error_message = "A fundação deve prover os cinco acessos AWS antes das stacks."
  }
  assert {
    condition = (
      aws_dynamodb_table.bets.hash_key == "bet_id" &&
      aws_dynamodb_table.executions.hash_key == "pk" &&
      aws_dynamodb_table.bets.billing_mode == "PAY_PER_REQUEST" &&
      aws_dynamodb_table.executions.billing_mode == "PAY_PER_REQUEST" &&
      one(aws_dynamodb_table.executions.ttl).attribute_name == "expires_at" &&
      one(aws_dynamodb_table.executions.ttl).enabled &&
      aws_dynamodb_table.bets.deletion_protection_enabled &&
      aws_dynamodb_table.executions.deletion_protection_enabled
    )
    error_message = "As tabelas precisam dos schemas reais, TTL e proteção de exclusão."
  }
  assert {
    condition = (
      aws_s3_bucket_public_access_block.artifacts.block_public_acls &&
      aws_s3_bucket_public_access_block.artifacts.block_public_policy &&
      aws_s3_bucket_public_access_block.artifacts.ignore_public_acls &&
      aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets &&
      one(aws_s3_bucket_ownership_controls.artifacts.rule).object_ownership == "BucketOwnerEnforced" &&
      one(aws_s3_bucket_versioning.artifacts.versioning_configuration).status == "Enabled" &&
      !aws_s3_bucket.artifacts.force_destroy
    )
    error_message = "Os artefatos devem ser privados, versionados e preservados."
  }
}
run "reject_open_ssh" {
  command = plan
  variables { ssh_ipv6_cidr = "::/0" }
  expect_failures = [var.ssh_ipv6_cidr]
}
