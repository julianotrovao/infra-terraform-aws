# outputs.tf

output "alb_dns_name" {
  description = "DNS Name do Application Load Balancer"
  value       = aws_lb.app_alb.dns_name
}

output "cloudfront_domain_name" {
  description = "Domain Name da Distribuição CloudFront (CDN) para acesso aos assets"
  value       = aws_cloudfront_distribution.s3_cdn.domain_name
}

output "route53_nameservers" {
  description = "Nameservers do Route 53. Você DEVE configurar estes NS no seu registrador de domínio."
  value       = aws_route53_zone.app_zone.name_servers
}

output "rds_endpoint" {
  description = "Endpoint da instância RDS para conexão da aplicação (privado)"
  value       = aws_db_instance.app_db.endpoint
  sensitive   = true
}
