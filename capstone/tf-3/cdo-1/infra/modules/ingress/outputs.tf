output "alb_dns_name" {
  description = "Internal ALB DNS is populated by the workload Ingress/Service after AWS Load Balancer Controller reconciles it."
  value       = try(kubernetes_ingress_v1.your_ingress.status[0].load_balancer[0].ingress[0].hostname, null)
}
