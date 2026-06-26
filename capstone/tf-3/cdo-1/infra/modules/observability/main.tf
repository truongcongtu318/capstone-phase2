# INFRA-7: Prometheus/Grafana/Alertmanager plus AWS-level CloudWatch logs.
# Alertmanager stays in-cluster and sends alerts to the receiver through ClusterIP.

locals {
  namespace          = "observability"
  grafana_service    = "kube-prometheus-stack-grafana"
  alert_receiver_url = "http://patch-receiver.self-heal-system.svc.cluster.local:8443/alerts"
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

resource "aws_cloudwatch_log_group" "eks_control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 90
  kms_key_id        = var.kms_observability_arn
  tags              = local.module_tags
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
    aws_cloudwatch_log_group.eks_control_plane,
    kubernetes_namespace.observability
  ]
}
