# variables.tf-arquivo devariaveis no terraform

variable "aws_region" {
  description = "A região da AWS para implantação (us-east-1 é a mais comum)"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "Bloco CIDR para a VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Número de Zonas de Disponibilidade a serem usadas (mínimo 2 para HA)"
  type        = number
  default     = 2
}

variable "instance_type" {
  description = "Tipo de instância para as máquinas EC2 no Auto Scaling Group"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "ID da AMI (Amazon Linux 2/Ubuntu) na sua região. ATUALIZE ESTE VALOR."
  type        = string
  # Exemplo de Amazon Linux 2 (us-east-1). Verifique o mais recente na sua região.
  default     = "ami-053b0d534c000d238" 
}

variable "db_engine" {
  description = "Motor do banco de dados (postgres ou mysql)"
  type        = string
  default     = "postgres"
}

variable "db_instance_class" {
  description = "Classe da instância RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_username" {
  description = "Nome de usuário mestre do banco de dados"
  type        = string
  default     = "appuser"
}

variable "db_password" {
  description = "Senha mestre do banco de dados (FORNECER ESTE VALOR AO EXECUTAR)"
  type        = string
  sensitive   = true # Marca a variável como sensível para não aparecer em logs
}

variable "domain_name" {
  description = "Nome de domínio para o Route 53 (Ex: minha-app-exemplo.com)"
  type        = string
  default     = "minha-app-exemplo.com"
}
