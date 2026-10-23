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
variable "stack_names" {
  type = object({ mail = string, gmail = string, whatsapp = string, bot = string, scheduler = string })
}
variable "parameters" {
  description = "Parâmetros CloudFormation; somente ARNs de secrets, nunca seu conteúdo."
  type        = object({ mail = map(string), gmail = map(string), whatsapp = map(string), bot = map(string), scheduler = map(string) })
  sensitive   = true
}
variable "artifact_parameters" {
  description = "Gerado pelo prepare.sh. Vazio durante a adoção preserva os artefatos atuais."
  type        = map(map(string))
  default     = {}
}

variable "scheduler_paused" {
  description = "Desabilita ambos os agendamentos durante manutenção sem perder os estados configurados em parameters.scheduler."
  type        = bool
  default     = false
}
