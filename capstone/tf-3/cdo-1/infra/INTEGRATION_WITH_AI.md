# Connect Base Infra (CDO) ↔ AI Engine Demo

Đọc sau khi Pack #1 (`INFRA-1..INFRA-4`: bootstrap, networking, security, eks) đã
apply xong. Mục tiêu: dựng AI Engine lên, test được `/v1/detect`, `/v1/decide`,
`/v1/verify` ngay trên cluster của CDO.

## 1. Sự thật quan trọng về demo của AI team

Folder `lab-w11/Capstone-Phase-2-CodeAI/demo` có 2 phần khác bản chất nhau:

| Phần | Dùng được không? | Vì sao |
|---|---|---|
| `app/` (FastAPI `main.py` + `Dockerfile`) | ✅ Dùng | Đúng contract: port 8080, `/health`, `/ready`, `/metrics`, 3 endpoint `/v1/*`. Đây là artifact thật cần build/push image. |
| `terraform/` (`vpc.tf`, `ecs.tf`, `alb.tf`, `iam.tf`) | ❌ KHÔNG dùng | Tự tạo VPC + ECS Fargate + ALB **riêng**, khác hoàn toàn topology đã ký trong `contracts/deployment-contract.md` (self-host **in-cluster EKS**, ClusterIP, namespace `self-heal-system`). Chính file `vpc.tf` của họ ghi chú thẳng: *"In a real scenario, you might just use data sources to fetch the CDO's VPC."* — họ cũng biết đây chỉ là demo tạm để tự test, không phải topology thật. |

→ Spin up `terraform/` của AI team **sẽ KHÔNG connect được** với EKS cluster của
CDO (2 VPC khác nhau, không peer, ALB riêng). Cái CDO cần là **image Docker**, không
phải hạ tầng của họ.

## 2. Cách connect thật (theo đúng contract đã ký)

```
AI team: docker build (app/) → push ECR (repo "tf-3-ai-engine", đã tạo sẵn qua
         demo/deploy_fixed.ps1 — CDO dùng lại repo này, không tạo trùng)
                    │
                    ▼
CDO: kubectl apply -f infra/manifests/ai-engine/  (namespace self-heal-system,
     trên EKS cluster vừa dựng ở INFRA-4)
                    │
                    ▼
Service ai-engine.self-heal-system.svc.cluster.local:8080  ← test từ trong cluster
```

Bước cụ thể:

1. **Lấy image**: AI team chạy `deploy_fixed.ps1` ít nhất 1 lần để image build &
   push lên ECR repo `tf-3-ai-engine` (script của họ đã làm sẵn bước build+push,
   chỉ cần bỏ qua phần họ tự `terraform apply` VPC/ECS/ALB).
2. **Apply manifest**: sửa `<ECR_IMAGE_URI>` trong
   `infra/manifests/ai-engine/deployment.yaml` thành URI thật, rồi:
   ```bash
   kubectl apply -f infra/manifests/ai-engine/
   kubectl -n self-heal-system rollout status deployment/ai-engine
   ```
3. **Test trong cluster** (vì service là ClusterIP, không expose ra ngoài —
   đúng Local Trust model):
   ```bash
   kubectl run curl-test --rm -it --image=curlimages/curl -n self-heal-system -- sh
   curl -X POST http://ai-engine.self-heal-system.svc.cluster.local:8080/v1/detect \
     -H "X-Tenant-Id: d3b07384-d113-495f-9f58-20d18d357d75" \
     -H "Idempotency-Key: $(uuidgen)" \
     -H "X-Dry-Run-Mode: true" \
     -H "Content-Type: application/json" \
     -d '{"idempotency_key":"...","dry_run_mode":true,"telemetry_window":[]}'
   ```
   Payload mẫu đầy đủ lấy từ `demo/readme.md` (đổi `Invoke-RestMethod` PowerShell
   thành `curl`, bỏ header `Authorization: AWS4-HMAC-SHA256 fake` — không cần SigV4
   theo bản contract Local Trust mới nhất).

## 3. Việc cần báo lại AI team (phát hiện khi đọc demo của họ)

1. **Tên S3 bucket / DynamoDB table phải khớp tuyệt đối**: IAM policy trong
   `demo/terraform/iam.tf` hardcode ARN `arn:aws:dynamodb:...:table/tf-3-aiops-idempotency-lock`
   và `arn:aws:s3:::tf-3-aiops-audit-trail/*`. CDO phải tạo đúng 2 tên này (đã ghi
   vào `infra/CLAUDE.md` mục 1) — nếu CDO đặt tên khác (vd `cdo-audit-bucket` như
   trong `docs/03_security_design.md` cũ) thì IRSA role thật của AI Engine sẽ bị
   `AccessDenied`.
2. **Cờ đỏ bảo mật**: `demo/terraform/iam.tf` cấp quyền
   `secretsmanager:GetSecretValue` trên secret `tf-3/ai-engine/kubeconfig-*` cho
   task role của AI Engine — nghĩa là AI Engine có thể tự lấy kubeconfig để gọi
   trực tiếp K8s API. Điều này **vi phạm** chính `deployment-contract.md` §3.A:
   *"AI Engine không có quyền truy cập trực tiếp vào Kubernetes (EKS) API... cấm
   lưu trữ kubeconfig trực tiếp trong môi trường chạy của AI Engine."* Cần AI team
   gỡ bỏ permission này khỏi IAM policy thật (ECS demo có thể bỏ qua vì không dùng,
   nhưng đừng copy pattern này khi build production IAM).
3. Header mẫu trong `demo/readme.md` vẫn dùng `Authorization: AWS4-HMAC-SHA256 fake`
   — sót lại từ bản contract SigV4 cũ, nên cập nhật theo Local Trust hiện tại (đã
   báo ở phần trước của conversation, file `ai-api-contract.md` 3 chỗ + `telemetry-contract.md` 1 chỗ).
