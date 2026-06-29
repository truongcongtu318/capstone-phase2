
# CDO-01 Monitoring

Thư mục này chứa cấu hình observability cho Self-Heal Platform.

## Trạng thái trước merge main

| Thành phần | Trạng thái | Ghi chú |
|---|---|---|
| `PrometheusRule` (prometheus-rules.yaml) | ✅ DONE — static manifest ready | Kustomize render OK |
| `AlertmanagerConfig` (alertmanager-config.yaml) | ✅ DONE — static manifest ready | Kustomize render OK |
| `prometheus-values.yaml` | ✅ DONE — Helm values ready | Truyền qua Terraform `helm_release` (Sub-team 1) |
| Grafana dashboard ConfigMap | ✅ DONE — static manifest ready | Sidecar nạp OK trên Minikube |
| `QueueBacklog` alert firing | ⏳ PENDING | Cần CloudWatch exporter / metric `tf3_cdo1_sqs_visible_messages` từ Sub-team 1 |
| `ServiceMonitor` (webhook-receiver) | ⏳ PENDING | App chưa expose `/metrics` endpoint |
| `ServiceMonitor` (ai-engine) | ⏳ PENDING | App chưa expose `/metrics` endpoint |
| `ServiceMonitor` (sqs-worker) | ⏳ PENDING | Background daemon, chưa có HTTP metrics port |
| Runtime alert evidence (cluster) | 🚫 BLOCKED\_BY\_INFRA | Cần EKS cluster + kubeconfig từ Sub-team 1 |

| File | Chức năng |
|---|---|
| `prometheus-values.yaml` | Helm values cho kube-prometheus-stack |
| `prometheus-rules.yaml` | Alert rules cho OOMKilled, CrashLoopBackOff và SQS backlog |
| `alertmanager-config.yaml` | Route alert self-heal đến Webhook Receiver |
| `dashboards/self-heal-overview.json` | Grafana dashboard |
| `kustomization.yaml` | Đóng gói PrometheusRule, AlertmanagerConfig và dashboard ConfigMap |

## Triển khai

`prometheus-values.yaml` không phải Kubernetes manifest và không được thêm vào
`kustomization.yaml`. Sub-team 1 truyền file này vào Terraform `helm_release`
của kube-prometheus-stack.

Các resource GitOps được render bằng:

```bash
kubectl kustomize capstone/tf-3/cdo-1/gitops/monitoring
````

Áp dụng thử trên cluster:

```bash
kubectl apply --dry-run=server \
  -k capstone/tf-3/cdo-1/gitops/monitoring
```

## Alert routing

Alertmanager chuyển các alert sau đến:

```text
http://webhook-receiver.self-heal-system.svc.cluster.local:8443/alerts
```

Các alert được route:

* `PodOOMKilled`
* `PodCrashLooping`
* `QueueBacklog`

## QueueBacklog metric contract

Rule `QueueBacklog` sử dụng metric:

```text
tf3_cdo1_sqs_visible_messages
```

Metric này phải được cung cấp bởi CloudWatch exporter hoặc recording rule sau khi
Sub-team 1 hoàn tất cấu hình thu thập metric SQS.

Label bắt buộc:

```text
queue="tf3-cdo1-sandbox-alert-queue"
```

Cho đến khi exporter được triển khai, rule được Prometheus load nhưng không firing.

## ServiceMonitor status

Hiện chưa tạo ServiceMonitor cho ba ứng dụng:

| Component          | Trạng thái                                                           |
| ------------------ | -------------------------------------------------------------------- |
| `webhook-receiver` | Manifest hiện dùng nginx placeholder, chưa expose `/metrics`         |
| `ai-engine`        | Manifest hiện dùng nginx placeholder, chưa expose `/metrics`         |
| `sqs-worker`       | Background daemon, chưa có HTTP metrics port hoặc Kubernetes Service |

Chỉ bổ sung ServiceMonitor khi application cung cấp đầy đủ:

1. HTTP endpoint `/metrics`.
2. Named container port.
3. Named Service port.
4. Stable Service selector.
5. Prometheus-format metrics trả về HTTP 200.

Ví dụ Service port yêu cầu:

```yaml
ports:
  - name: metrics
    port: 9090
    targetPort: metrics
```

ServiceMonitor phải tham chiếu tên port, không tham chiếu trực tiếp port number:

```yaml
endpoints:
  - port: metrics
    path: /metrics
```

## Kiểm thử đã thực hiện

* Helm lint kube-prometheus-stack `59.1.0`.
* Helm template thành công.
* Prometheus, Alertmanager và Grafana chạy trên Minikube profile riêng.
* Prometheus load đủ ba custom alert rules.
* Alertmanager load `AlertmanagerConfig`.
* Synthetic alert được gửi thành công đến webhook `/alerts`.
* Pod CrashLoopBackOff thực tế kích hoạt alert và webhook.
* Grafana sidecar nạp dashboard thành công.
* Kustomize render và apply thành công.

```
