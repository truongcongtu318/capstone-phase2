# ST2 → ST3 Handoff — Deployment Specification

> Tài liệu này cung cấp mọi thông số ST3 cần để viết Kustomize overlays, Prometheus scrape config, và test trên EKS sandbox.

---

## 1. Images (ECR)

Sau khi CI pipeline chạy thành công trên `main`, 3 image được build và push lên ECR:

| Service | ECR Repository | Port |
|---|---|---|
| Webhook Receiver | `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-webhook-receiver` | `8443` |
| SQS Worker | `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-self-heal-worker` | metrics: `9090` |
| AI Engine Demo | `474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-ai-engine-demo` | `8080` |

**Image tag format:** `sha-<git-sha>` (ví dụ: `sha-a1b2c3d4e5f6...`)

**Namespace:** `self-heal-system`

---

## 2. Webhook Receiver

### Container spec
```yaml
image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-webhook-receiver:sha-<TAG>
ports:
  - containerPort: 8443
    name: https
livenessProbe:
  httpGet:
    path: /health
    port: 8443
  initialDelaySeconds: 10
  periodSeconds: 15
readinessProbe:
  httpGet:
    path: /health
    port: 8443
  initialDelaySeconds: 5
  periodSeconds: 10
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Environment variables (từ ConfigMap + Secret)

| Var | Giá trị | Source |
|---|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` | ConfigMap |
| `SQS_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue` | ConfigMap |
| `DYNAMODB_TABLE_NAME` | `tf-3-aiops-idempotency-lock` | ConfigMap |
| `DRY_RUN` | `false` | ConfigMap |

**Không set** `DYNAMODB_ENDPOINT_URL`, `SQS_ENDPOINT_URL` — boto3 tự dùng IRSA.

### ServiceAccount + IRSA
```yaml
serviceAccountName: webhook-receiver
# Annotation trên ServiceAccount:
# eks.amazonaws.com/role-arn: arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-webhook-receiver
```

### Prometheus scrape annotations
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8443"
  prometheus.io/path: "/metrics"
```

---

## 3. SQS Worker

### Container spec
```yaml
image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-self-heal-worker:sha-<TAG>
ports:
  - containerPort: 9090
    name: metrics
# Không expose HTTP port — worker là SQS daemon (không có HTTP server ngoài /metrics)
livenessProbe:
  httpGet:
    path: /metrics
    port: 9090
  initialDelaySeconds: 15
  periodSeconds: 30
resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```

### Environment variables

| Var | Giá trị | Source |
|---|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` | ConfigMap |
| `SQS_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/474013238625/tf3-cdo1-sandbox-self-heal-queue` | ConfigMap |
| `SNS_TOPIC_ARN` | `arn:aws:sns:us-east-1:474013238625:tf3-cdo1-sandbox-alerts-escalation` | ConfigMap |
| `FIREHOSE_STREAM_NAME` | `tf3-cdo1-sandbox-audit-stream` | ConfigMap |
| `DYNAMODB_TABLE_NAME` | `tf-3-aiops-idempotency-lock` | ConfigMap |
| `AI_ENGINE_URL` | `http://ai-engine.self-heal-system.svc.cluster.local:8080` | ConfigMap |
| `DRY_RUN` | `false` | ConfigMap |

**Không set** `*_ENDPOINT_URL` — boto3 tự dùng IRSA.

### ServiceAccount + IRSA
```yaml
serviceAccountName: self-heal-executor
# Annotation trên ServiceAccount:
# eks.amazonaws.com/role-arn: arn:aws:iam::474013238625:role/tf3-cdo1-sandbox-irsa-audit-writer
```

### Prometheus scrape annotations
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
  prometheus.io/path: "/metrics"
```

---

## 4. AI Engine Demo (Tạm dùng thay AI Engine thật)

> AI Engine thật chưa có API chính thức. Tạm dùng demo skeleton — trả response hợp lệ theo contract nhưng cứng kết quả.

### Container spec
```yaml
image: 474013238625.dkr.ecr.us-east-1.amazonaws.com/tf-3-ai-engine-demo:sha-<TAG>
ports:
  - containerPort: 8080
    name: http
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 15
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 1000m
    memory: 2Gi
```

### Service (ClusterIP — internal only)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: ai-engine
  namespace: self-heal-system
spec:
  selector:
    app: ai-engine
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
```

**URL mà worker gọi:** `http://ai-engine.self-heal-system.svc.cluster.local:8080`

> Khi AI Engine thật sẵn sàng: chỉ đổi image tag và image repo — không cần thay đổi Service hay env vars.

---

## 5. Metrics ST3 cần monitor (Prometheus)

### Webhook Receiver
| Metric | Type | Ý nghĩa |
|---|---|---|
| `http_request_duration_seconds{handler="/alerts"}` | Histogram | Latency nhận alert |
| `webhook_alerts_queued_total{tenant_id}` | Counter | Alert được push SQS |
| `webhook_security_violations_total` | Counter | Số lần reject 403 |
| `webhook_duplicate_alerts_total{tenant_id}` | Counter | Số lần reject 409 (duplicate) |

### SQS Worker
| Metric | Type | Ý nghĩa |
|---|---|---|
| `worker_messages_processed_total{status}` | Counter | Tổng message: COMPLETED/FAILED/DRY_RUN |
| `worker_ai_call_duration_seconds{endpoint}` | Histogram | AI Engine latency per endpoint |
| `worker_ai_errors_total{endpoint,status_code}` | Counter | Lỗi AI Engine |
| `worker_executions_total{action,lane,status}` | Counter | K8s patch executions |
| `worker_circuit_breaker_open_total{tenant_id}` | Counter | CB flip to OPEN |
| `worker_circuit_breaker_skips_total{tenant_id}` | Counter | Message bị skip do CB OPEN |
| `worker_escalations_total{reason}` | Counter | Escalate to SRE |
| `worker_rollbacks_total{status}` | Counter | Rollback attempts |

---

## 6. Quy trình test trên production (EKS sandbox)

### Bước 1: Verify images đã có trên ECR
```bash
aws ecr list-images --repository-name tf-3-webhook-receiver --region us-east-1
aws ecr list-images --repository-name tf-3-self-heal-worker --region us-east-1
aws ecr list-images --repository-name tf-3-ai-engine-demo --region us-east-1
```

### Bước 2: ST3 deploy qua ArgoCD
ST3 cập nhật Kustomize overlay với image tag mới nhất → ArgoCD sync → pods lên.

### Bước 3: Verify pods healthy
```bash
kubectl get pods -n self-heal-system
# Expected: webhook-receiver, sqs-worker, ai-engine tất cả Running
kubectl logs -n self-heal-system -l app=sqs-worker --tail=20
```

### Bước 4: Test end-to-end

Lấy Webhook URL từ Ingress của ST3:
```bash
WEBHOOK_URL=$(kubectl get ingress -n self-heal-system -o jsonpath='{.items[0].spec.rules[0].host}')
```

Gửi alert tenant-payment (OOMKilled):
```bash
curl -s -X POST "https://$WEBHOOK_URL/alerts" \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "PodOOMKilled",
        "namespace": "tenant-payment",
        "service": "order-service",
        "severity": "critical"
      },
      "annotations": {"summary": "OOM Kill detected"}
    }]
  }'
# Expected: {"status":"accepted"}
```

### Bước 5: Verify Prometheus metrics
```bash
# Port-forward tới worker metrics
kubectl port-forward -n self-heal-system svc/sqs-worker 9090:9090 &
curl -s http://localhost:9090/metrics | grep worker_messages_processed
```

### Bước 6: Verify audit log lên Firehose/S3
```bash
# Chờ ~5 phút cho Firehose buffer flush
aws s3 ls s3://tf-3-aiops-audit-trail/ --recursive | sort | tail -5
```

---

## 7. Hành vi khi dùng AI Engine Demo

AI demo đã được cập nhật để echo namespace từ request payload (giống AI Engine thật). Pipeline chạy đến **COMPLETED** với `DRY_RUN=true`.

**Happy path với DRY_RUN=true:**
```
INCIDENT_START → DETECT → DECIDE → EXECUTE_START (DRY_RUN skip K8s) → EXECUTE_DONE → VERIFY → DONE
worker_messages_processed_total{status="DRY_RUN"} tăng
```

**Giới hạn còn lại:**

| Hành vi | Lý do |
|---|---|
| AI luôn trả `anomaly_detected=true` | Demo skeleton cứng kết quả |
| AI luôn trả `next_action=DONE` | Demo không có verify logic thật |
| K8s patch và Git commit không thật | `DRY_RUN=true` — xem log `[DRY_RUN]` |
| Không test được ROLLBACK/ESCALATE từ verify | Cần AI Engine thật hoặc inject thủ công |

**Khi AI Engine thật deploy:** chỉ đổi image tag trong Kustomize overlay — không cần thay đổi Service, env vars, hay bất kỳ config nào khác.

---

## 8. Liên hệ ST2

- Lead: Tan (PM + ST2 Lead)
- GitHub branch naming: `app/<component>-<desc>`
- ECR repos được tạo bởi ST1 Terraform (liên hệ ST1 nếu repo chưa tồn tại)
