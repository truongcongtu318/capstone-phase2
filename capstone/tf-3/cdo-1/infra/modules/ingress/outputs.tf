output "alb_dns_name" {
  description = "Internal ALB DNS is populated by the workload Ingress/Service after AWS Load Balancer Controller reconciles it."
  value       = null
}
