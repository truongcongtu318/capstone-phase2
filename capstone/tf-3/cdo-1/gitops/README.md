# ☸️ GitOps, Kubernetes Manifests & ArgoCD Guide (Sub-team 3)

Thư mục này chứa toàn bộ tài nguyên cấu hình Kubernetes, ArgoCD Application Manifests, Kyverno Admission Policies và Network Policies để quản trị vòng đời ứng dụng của hệ thống tự chữa lành **CDO-01**.

## 📂 Tổ chức Thư mục GitOps

Để đảm bảo khả năng mở rộng hệ thống theo chuẩn **GitOps & Kustomize Overlays**, cấu trúc thư mục được thiết kế chi tiết như sau:

```text
gitops/
├── argo-apps/                        # Cấu hình ArgoCD App-of-Apps
│   ├── root-application.yaml         # Application gốc quản lý toàn bộ các ứng dụng con
│   ├── webhook-receiver-app.yaml     # Khai báo Webhook App trong cụm ArgoCD
│   ├── sqs-worker-app.yaml           # Khai báo SQS Worker App trong cụm ArgoCD
│   └── ai-engine-app.yaml            # Khai báo AI Engine App trong cụm ArgoCD
│
├── manifests/                        # Kustomize Base & Overlays Layout cho K8s objects
│   ├── base/                         # Cấu hình manifests nền (dùng chung cho mọi môi trường)
│   │   ├── webhook-receiver/         # deployment.yaml, service.yaml, kustomization.yaml
│   │   ├── sqs-worker/               # deployment.yaml, serviceaccount.yaml (gán IRSA), kustomization.yaml
│   │   └── ai-engine/                # deployment.yaml, service.yaml, external-secret.yaml, kustomization.yaml
│   │
│   └── overlays/                     # Ghi đè cấu hình cho từng môi trường chạy thực tế
│       └── sandbox/                  # Cấu hình riêng biệt của môi trường Sandbox
│           ├── webhook-receiver/     # patch-env.yaml, kustomization.yaml
│           ├── sqs-worker/           # patch-replicas.yaml, kustomization.yaml
│           ├── ai-engine/            # patch-image.yaml (ecr docker tags), kustomization.yaml
│           └── kustomization.yaml    # Điểm tập hợp overlays môi trường Sandbox
│
├── security-policies/                # Chính sách bảo mật bắt buộc (Admission Control & Network Isolation)
│   ├── restrict-mutations.yaml       # Kyverno ClusterPolicy giới hạn quyền tự sửa đổi trong cụm
│   └── network-policies/             # Phân vùng bảo mật mạng
│       ├── ai-engine-netpolicy.yaml  # NetworkPolicy cô lập container AI Engine
│       └── webhook-netpolicy.yaml    # NetworkPolicy giới hạn Ingress webhook receiver
│
└── monitoring/                       # Giám sát & Dashboard (Prometheus Alertmanager configs)
```

---

## 🔒 Quy Định Bảo Mật Cụm EKS (Strict Security Hardening)

Nhóm **Sub-team 3** chịu trách nhiệm cấu hình và thực thi tuyệt đối các quy định bảo mật mạng và chính sách nhập cụm (Admission Policies):

### 1. Phân vùng mạng cô lập (NetworkPolicies)
*   **AI Engine Isolation (`ai-engine-netpolicy.yaml`):** 
    Container AI Engine là tài nguyên nhạy cảm (giao tiếp trực tiếp với AWS Bedrock). Bắt buộc phải khóa cứng NetworkPolicy: block toàn bộ Ingress/Egress từ các namespaces hoặc pods khác, **chỉ cho phép** kết nối Ingress đi vào Port `8080` của AI Engine từ các Pods gán nhãn `app=sqs-worker` và `app=webhook-receiver` trong namespace `self-heal-system`.
*   **Webhook Isolation (`webhook-netpolicy.yaml`):**
    Webhook Receiver mở Port `8443` để tiếp nhận Alert payload. Ingress NetworkPolicy chỉ cho phép traffic đi vào Port này từ cụm IP của Prometheus/Alertmanager (hoặc ingress controller).

### 2. Kyverno Admission Guardrails (`restrict-mutations.yaml`)
Hệ thống tự chữa lành có tính năng tự động vá lỗi (Fast Lane), cho phép Worker sửa trực tiếp thông số EKS qua API Client. Để tránh lạm dụng quyền và bảo vệ an toàn hệ thống, cấu hình Kyverno ClusterPolicy bắt buộc phải chặn đứng mọi hành động cập nhật tài nguyên từ Worker, **ngoại trừ** hai thông số duy nhất sau được phép thay đổi:
1.  `spec.replicas` (Khi scale-up xử lý hàng chờ).
2.  `spec.template.spec.containers[*].resources.limits` (Khi nâng cấu hình khắc phục lỗi OOMKilled).

Bất kỳ hành động sửa đổi cấu hình K8s nào khác (ví dụ: thay đổi image name, sửa volume, thay đổi port...) do Worker hoặc AI Engine gửi lên EKS API đều sẽ bị Kyverno Admission Controller **từ chối (Block)** ngay lập tức.
