# main.tf - Infraestrutura Completa AWS via Terraform

# Configuração do Provedor AWS
provider "aws" {
  region = var.aws_region
}

# O bloco de código usa loops (count) e funções (cidrsubnet) para criar recursos
# automaticamente em múltiplas AZs, garantindo Alta Disponibilidade (HA).

# ----------------------------------------------------
# 1. Rede (VPC, Subnets, Gateways, Route Tables)
# ----------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "AppVPC" }
}

# Busca as AZs disponíveis na região
data "aws_availability_zones" "available" {
  state = "available"
}

# Subnets Públicas (10.0.0.0/24, 10.0.1.0/24, ...)
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  # Usa blocos CIDR iniciais: 10.0.0.0/24, 10.0.1.0/24, etc.
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index) 
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "PublicSubnet-${count.index + 1}" }
}

# Subnets Privadas (10.0.10.0/24, 10.0.11.0/24, ...)
resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  # Usa blocos CIDR mais altos: 10.0.10.0/24, 10.0.11.0/24, etc.
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10) 
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "PrivateSubnet-${count.index + 1}" }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "AppIGW" }
}

# Elastic IP (para o NAT Gateway)
resource "aws_eip" "nat" {
  vpc = true
  tags = { Name = "NATGatewayEIP" }
}

# NAT Gateway (colocado na primeira Subnet Pública)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags = { Name = "AppNATGateway" }
}

# Tabela de Rotas Pública (Rota 0.0.0.0/0 -> IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "PublicRouteTable" }
}

# Tabela de Rotas Privada (Rota 0.0.0.0/0 -> NAT Gateway)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "PrivateRouteTable" }
}

# Associações de Rotas
resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ----------------------------------------------------
# 2. Security Groups (SG-ALB, SG-EC2, SG-RDS)
# ----------------------------------------------------

# SG-ALB: Acesso de entrada 80/443 de qualquer lugar
resource "aws_security_group" "alb" {
  name        = "sg-alb"
  description = "Permite tráfego HTTP/HTTPS de entrada"
  vpc_id      = aws_vpc.main.id
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

# SG-EC2: Acesso de entrada 80 apenas do ALB
resource "aws_security_group" "ec2" {
  name        = "sg-ec2"
  description = "Permite tráfego HTTP apenas do ALB"
  vpc_id      = aws_vpc.main.id
  ingress { 
    from_port = 80; to_port = 80; protocol = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

# SG-RDS: Acesso de entrada do BD apenas das EC2 (5432 para Postgres)
resource "aws_security_group" "rds" {
  name        = "sg-rds"
  description = "Permite tráfego de BD apenas das instâncias EC2"
  vpc_id      = aws_vpc.main.id
  ingress { 
    from_port = 5432; to_port = 5432; protocol = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

# ----------------------------------------------------
# 3. IAM (Role para EC2 com acesso ao S3)
# ----------------------------------------------------

resource "aws_iam_role" "ec2_role" {
  name = "AppEC2Role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

# Policy de acesso ao S3 (será criada no passo 6)
resource "aws_iam_policy" "s3_access_policy" {
  name        = "AppS3ReadWritePolicy"
  description = "Permite que a EC2 leia e escreva no bucket de assets"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      Effect = "Allow",
      Resource = ["${aws_s3_bucket.assets.arn}", "${aws_s3_bucket.assets.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_s3_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "AppEC2Profile"
  role = aws_iam_role.ec2_role.name
}

# ----------------------------------------------------
# 4. EC2, Launch Template, ALB e Auto Scaling Group
# ----------------------------------------------------

# Target Group do ALB
resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check { path = "/"; port = 80 }
}

# Application Load Balancer (ALB) - em subnets públicas
resource "aws_lb" "app_alb" {
  name               = "app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public.*.id 
  tags = { Name = "AppALB" }
}

# Listener do ALB (escuta na porta 80 e encaminha para o Target Group)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.app_tg.arn }
}

# Launch Template (define a configuração da instância)
resource "aws_launch_template" "app_lt" {
  name_prefix   = "app-lt-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile { arn = aws_iam_instance_profile.ec2_profile.arn }
  
  # User data para instalar um servidor web simples (simulação de deploy)
  user_data = base64encode(
    <<-EOF
      #!/bin/bash
      yum update -y
      yum install -y httpd
      systemctl start httpd
      echo "<h1>Deploy via Terraform e ASG</h1>" > /var/www/html/index.html
    EOF
  )
}

# Auto Scaling Group (em subnets privadas)
resource "aws_autoscaling_group" "app_asg" {
  name                      = "app-asg"
  vpc_zone_identifier       = aws_subnet.private.*.id # Instâncias em subnets privadas
  target_group_arns         = [aws_lb_target_group.app_tg.arn]
  min_size                  = 2
  max_size                  = 6
  desired_capacity          = 2
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template { id = aws_launch_template.app_lt.id; version = "$Latest" }

  tag { key = "Name"; value = "AppInstance"; propagate_at_launch = true }
}

# Políticas e Alarmes de Scaling (CloudWatch integrado com ASG)

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "cpu-greater-than-70-scale-out"
  scaling_adjustment     = 2
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu-high-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70 # CPU > 70%
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.app_asg.name }
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "cpu-less-than-30-scale-in"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "cpu-low-alarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 30 # CPU < 30%
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.app_asg.name }
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]
}


# ----------------------------------------------------
# 5. RDS (Banco de Dados)
# ----------------------------------------------------

# Subnet Group para o RDS (usa as subnets privadas)
resource "aws_db_subnet_group" "rds" {
  name       = "rds-subnet-group"
  subnet_ids = aws_subnet.private.*.id 
  tags = { Name = "AppRDS-SubnetGroup" }
}

# Instância RDS PostgreSQL (ou MySQL, conforme variável)
resource "aws_db_instance" "app_db" {
  identifier           = "app-database"
  engine               = var.db_engine
  engine_version       = var.db_engine == "postgres" ? "14.7" : "8.0.35"
  instance_class       = var.db_instance_class
  allocated_storage    = 20
  db_subnet_group_name = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  # Alta Disponibilidade (Multi-AZ)
  multi_az             = true 
  
  name                 = "maindb"
  username             = var.db_username
  password             = var.db_password
  skip_final_snapshot  = true 
  backup_retention_period = 7 # 7 dias de backup conforme pedido
}

# ----------------------------------------------------
# 6. S3 (Assets) e CloudFront (CDN)
# ----------------------------------------------------

# Bucket S3 para Assets (usa o Account ID para nome único)
resource "aws_s3_bucket" "assets" {
  bucket = "app-assets-bucket-${trimspace(var.aws_region)}-017121235801" 
  tags = { Name = "AppAssetsBucket" }
}

# Bloqueia o acesso público (conforme pedido)
resource "aws_s3_bucket_public_access_block" "assets_block" {
  bucket = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# OAI (Origin Access Identity) para CloudFront
resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "OAI para acesso ao bucket S3"
}

# Policy do S3 para permitir acesso APENAS pelo CloudFront OAI
resource "aws_s3_bucket_policy" "assets_policy" {
  bucket = aws_s3_bucket.assets.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid    = "AllowCloudFrontAccess",
      Effect = "Allow",
      Principal = { AWS = aws_cloudfront_origin_access_identity.oai.iam_arn },
      Action = "s3:GetObject",
      Resource = "${aws_s3_bucket.assets.arn}/*"
    }]
  })
}

# Distribuição CloudFront (CDN)
resource "aws_cloudfront_distribution" "s3_cdn" {
  origin {
    domain_name = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.assets.id
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_id
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html" 

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_s3_bucket.assets.id
    viewer_protocol_policy = "redirect-to-https"
    default_ttl = 3600
    max_ttl     = 86400
    forwarded_values { query_string = false; cookies { forward = "none" } }
  }

  restrictions { geo_restriction { restriction_type = "none" } }

  # Assume que o certificado ACM será provisionado separadamente, usa o padrão por simplicidade
  viewer_certificate { cloudfront_default_certificate = true }
}

# ----------------------------------------------------
# 7. Route 53 (DNS)
# ----------------------------------------------------

# Cria a Zona Hospedada para o seu domínio
resource "aws_route53_zone" "app_zone" {
  name = var.domain_name
}

# Registro A/Alias para o ALB (ex: www.minha-app-exemplo.com)
resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.app_zone.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.app_alb.dns_name
    zone_id                = aws_lb.app_alb.zone_id
    evaluate_target_health = true
  }
}

# Registro A/Alias para o CloudFront (ex: assets.minha-app-exemplo.com)
resource "aws_route53_record" "cdn" {
  zone_id = aws_route53_zone.app_zone.zone_id
  name    = "assets.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.s3_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
