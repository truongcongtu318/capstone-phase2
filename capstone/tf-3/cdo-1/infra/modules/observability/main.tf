# INFRA-7: Prometheus/Grafana/Alertmanager plus AWS-level CloudWatch logs.
# Alertmanager stays in-cluster and sends alerts to the receiver through ClusterIP.

locals {
  namespace       = "observability"
  grafana_service = "kube-prometheus-stack-grafana"

  # FIX lỗi 4: "patch-receiver" không có Service backing
  # CLAUDE.md §2: Webhook Receiver = FastAPI, namespace self-heal-system
  # port: 8000 (FastAPI default), path: /alert (không phải /alerts)
  alert_receiver_url = "http://webhook-receiver.self-heal-system.svc.cluster.local:8000/alert"

  # CLAUDE.md §4: Component tag cho Cost Explorer
  module_tags = merge(var.tags, {
    Component = "observability"
  })
}

# FIX lỗi 2: Terraform tạo log group TRƯỚC khi EKS enable logging
# → tránh ResourceAlreadyExists khi EKS tự tạo cùng tên
# Phương án chọn: Terraform quản lý (tạo trước, EKS dùng lại)
# Nếu log group đã tồn tại trên AWS, chạy:
#   terraform import aws_cloudwatch_log_group.eks_control_plane /aws/eks/<cluster_name>/cluster
resource "aws_cloudwatch_log_group" "eks_control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30

  # FIX lỗi 1 (phần observability): encrypt bằng observability CMK
  # Yêu cầu KMS key policy trong modules/security phải có statement
  # AllowCloudWatchLogs cho principal logs.<region>.amazonaws.com
  kms_key_id = var.kms_observability_arn # CLAUDE.md §2: output từ security module

  tags = local.module_tags
}

resource "kubernetes_namespace" "observability" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/name"       = local.namespace
      "platform.tf3-cdo1/protected"  = "true"
      "self-heal.tf3-cdo1/mutate-ok" = "false"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  version    = "61.7.2"

  values = [
    yamlencode({
      fullnameOverride = "kube-prometheus-stack"

      alertmanager = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        alertmanagerSpec = {
          replicas = 1
        }
        config = {
          global = {
            resolve_timeout = "5m"
          }
          route = {
            group_by        = ["alertname", "namespace", "service"]
            group_wait      = "10s"
            group_interval  = "1m"
            repeat_interval = "30m"
            receiver        = "self-heal-receiver"
          }
          receivers = [
            {
              name = "self-heal-receiver"
              webhook_configs = [
                {
                  url           = local.alert_receiver_url
                  send_resolved = true
                }
              ]
            }
          ]
        }
      }

      grafana = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        sidecar = {
          dashboards = {
            enabled = true
          }
          datasources = {
            enabled = true
          }
        }
      }

      prometheus = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        prometheusSpec = {
          retention                               = "7d"
          replicas                                = 1
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
        }
      }

      prometheusOperator = {
        enabled = true
      }

      "kube-state-metrics" = {
        enabled = true
      }

      "prometheus-node-exporter" = {
        enabled = true
      }
    })
  ]

  depends_on = [
    # Log group phải tồn tại trước khi stack observability deploy
    aws_cloudwatch_log_group.eks_control_plane,
    kubernetes_namespace.observability,
  ]
}
