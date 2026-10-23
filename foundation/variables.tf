variable "region" {
  type    = string
  default = "us-east-1"
}
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Informe o ID AWS de 12 dígitos."
  }
}
variable "name" {
  type    = string
  default = "loto"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.name))
    error_message = "Use de 2 a 20 caracteres minúsculos, números ou hífen, iniciando com letra."
  }
}
variable "ssh_public_key_path" {
  type        = string
  description = "Caminho da chave pública OpenSSH. A chave privada nunca entra no state."
}
variable "ssh_ipv6_cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.ssh_ipv6_cidr, 0)) && can(regex("^[0-9a-fA-F:]+/128$", var.ssh_ipv6_cidr))
    error_message = "Informe somente seu IPv6 público com /128."
  }
}
variable "ses_from" {
  type        = string
  description = "E-mail remetente; confirme o link de verificação recebido após o apply."
}
