output "cluster_name" {
  value = module.eks.cluster_name
}

output "alb_dns_name" {
  value = module.ingress.alb_dns_name
}

# Smoke test outputs (kubeconfig command, grafana access URL...) — cố tình bỏ
# trống, PM tự bổ sung theo cách chia ticket riêng cho phần smoke test.
