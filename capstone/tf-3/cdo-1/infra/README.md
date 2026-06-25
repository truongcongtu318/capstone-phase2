# infra/ — Base Infra (Evidence Pack #1: VPC + Cluster + Observability)

Cấu trúc bám theo `docs/04_deployment_design.md` §1.2. Mỗi module = 1 Jira ticket
= 1 owner. Đọc `CLAUDE.md` trong folder này trước khi code.

| Ticket | Module | Path | Phụ thuộc |
|---|---|---|---|
| INFRA-1 | Bootstrap (state backend, OIDC) | `bootstrap/` | — |
| INFRA-2 | Networking (VPC, subnet, endpoint) | `modules/networking/` | INFRA-1 |
| INFRA-3 | Security (SG, KMS) | `modules/security/` | INFRA-1 |
| INFRA-4 | **EKS cluster + Karpenter** (gộp vì dependency chặt, tách 2 người chỉ tạo chờ nhau) | `modules/eks/`, `modules/karpenter/` | INFRA-2, INFRA-3 |
| INFRA-5 | Ingress (ALB internal) | `modules/ingress/` | INFRA-4 |
| INFRA-6 | Observability (Prometheus/Grafana) | `modules/observability/` | INFRA-4 |
| INFRA-7 | **Cost Allocation Tagging** (mới — Component tag mỗi module + activate ở Cost Explorer) | `*/tags.tf`, `cost-allocation-tags.tf` | INFRA-1 (chạy song song, không block ai) |

7 ticket cho 8 người — 1 người dư ra nên pair với INFRA-4 (nặng nhất) hoặc làm
floater. Smoke test cuối cùng PM tự chia riêng (xem mục "Cố tình chưa làm").

Sau khi INFRA-1→4 chạy xong, đọc `INTEGRATION_WITH_AI.md` để dựng AI Engine demo
lên cluster và test API thật (`manifests/ai-engine/`).

## Đã gộp sẵn (pre-wired) — không cần tự nối input/output

Root composition trong `environments/sandbox/foundation/*.tf` đã wire sẵn toàn bộ
chain phụ thuộc:

- `networking.tf` → gọi `modules/networking`
- `security.tf` → nhận `vpc_id`, `vpc_cidr` từ `module.networking`
- `eks.tf` → nhận subnet/SG/KMS từ `module.networking` + `module.security`
- `karpenter.tf` → nhận `cluster_name`, `oidc_provider_arn` từ `module.eks`
- `ingress.tf` → nhận cluster info từ `module.eks`, SG từ `module.security`
- `observability.tf` → nhận cluster info từ `module.eks`, KMS từ `module.security`

Mỗi owner chỉ cần điền `main.tf` (+ `outputs.tf` thật) của module mình theo đúng
TODO đã ghi sẵn trong file — không phải tự viết phần wiring.

## Thứ tự apply thực tế

```
bootstrap
  └─→ networking + security (song song)
        └─→ eks
              └─→ karpenter + ingress + observability (song song)
```

`providers.tf` ở root dùng `module.eks` output cho kubernetes/helm provider — vì
vậy lần apply đầu tiên cần `terraform apply -target=module.eks` trước, sau đó
apply phần còn lại (chicken-and-egg kinh điển khi cluster vừa là resource vừa là
provider target).

## Cố tình chưa làm

Smoke test cuối cùng (apply toàn bộ Pack #1 + verify "chạy được") **không nằm
trong skeleton này** — PM tự tính toán chia ticket riêng cho phần đó.
