# Connect CDO Infra ↔ AI Engine

Đọc sau khi Pack #1 (INFRA-1→4) apply xong. Xem `DEPLOY_AND_TEST_GUIDE.md` để
biết hướng dẫn build image và test step-by-step.

---

## 1. Source code AI Engine

Source đã được copy từ `lab-w11/Capstone-Phase-2-CodeAI/demo/app/` vào:
```
manifests/ai-engine/main.py            ← FastAPI dummy engine
manifests/ai-engine/Dockerfile         ← python:3.11-slim, port 8080
manifests/ai-engine/requirements.txt   ← fastapi, uvicorn
```

App là dummy engine — mọi `/v1/detect` luôn trả về `anomaly_detected: true`,
`/v1/decide` luôn trả về action plan mẫu. Đủ để test luồng E2E Pack #1.

**KHÔNG dùng** `lab-w11/.../demo/terraform/` — stack ECS/VPC riêng của AI team,
không phải topology EKS đã ký trong `contracts/deployment-contract.md`.

---

## 2. Topology kết nối (theo contract đã ký)

```
ECR (tf-3-ai-engine image)
         │
         ▼
AI Engine Deployment  ← manifests/ai-engine/deployment.yaml
namespace: self-heal-system
ClusterIP: ai-engine.self-heal-system.svc.cluster.local:8080
         ▲
         │  HTTP POST /v1/detect, /v1/decide, /v1/verify
         │  (KHÔNG dùng Authorization header — Local Trust, đã bỏ SigV4)
         │
patch-receiver (webhook-receiver)
ClusterIP: patch-receiver.self-heal-system.svc.cluster.local:8443
         ▲
         │  POST /alerts (Alertmanager webhook format)
         │
Alertmanager (namespace: observability)
```

Tất cả traffic đi qua ClusterIP nội bộ, không qua ALB hay Internet.
Bảo vệ network bằng NetworkPolicy (`manifests/ai-engine/networkpolicy.yaml`).

---

## 3. Yêu cầu bắt buộc từ phía CDO (AI team cần biết)

### 3.1 Tên tài nguyên AWS phải khớp tuyệt đối

AI Engine's IAM policy hardcode các ARN sau (xem `docs/03_security_design.md` và
`CLAUDE.md §1`). Nếu CDO đặt tên khác → AI Engine bị `AccessDenied`:

| Tài nguyên | Tên bắt buộc |
|---|---|
| DynamoDB idempotency lock | `tf-3-aiops-idempotency-lock` |
| S3 audit bucket | `tf-3-aiops-audit-trail` |
| Namespace K8s | `self-heal-system` |

### 3.2 Trust model đã thay đổi — không dùng SigV4

AI team đã bỏ `Authorization: AWS Signature Version 4` header.
CDO call AI Engine **không cần** và **không nên** thêm Authorization header.
Header bắt buộc là: `X-Tenant-Id`, `Idempotency-Key`, `X-Dry-Run-Mode`.

### 3.3 NetworkPolicy — label bắt buộc cho caller

Chỉ pod có label `app=cdo-self-heal-controller` mới được gọi vào AI Engine port 8080.
Webhook receiver (`patch-receiver`) đã được gán label này.

---

## 4. Kiểm tra nhanh sau khi AI Engine chạy

```bash
# Từ trong cluster, gọi /v1/detect
IKEY=$(uuidgen | tr '[:upper:]' '[:lower:]')
kubectl run quick-test --rm -it --restart=Never \
  --image=curlimages/curl -n self-heal-system \
  --labels="app=cdo-self-heal-controller" \
  -- curl -s -X POST \
  http://ai-engine.self-heal-system.svc.cluster.local:8080/v1/detect \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
  -H "Idempotency-Key: $IKEY" \
  -H "X-Dry-Run-Mode: true" \
  -d "{\"idempotency_key\":\"$IKEY\",\"dry_run_mode\":true,\"telemetry_window\":[]}"
```

Xem `DEPLOY_AND_TEST_GUIDE.md §5` để test E2E với Alertmanager.

---

## 5. Cờ đỏ cần báo lại AI team

Nếu AI team có demo cũ dùng ECS/Terraform với IAM:
- Policy đó có thể có `secretsmanager:GetSecretValue` cho secret `tf-3/ai-engine/kubeconfig-*`
  → vi phạm `deployment-contract.md §3.A` ("AI Engine không có quyền truy cập K8s API,
  không lưu kubeconfig"). Cần xóa khỏi IAM policy production.
- Header `Authorization: AWS4-HMAC-SHA256` trong readme demo cũ → không dùng trong
  Local Trust model hiện tại.
