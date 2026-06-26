# ☸️ GitOps, Kubernetes Manifests & ArgoCD Guide (Sub-team 3)

Thư mục này chứa toàn bộ tài nguyên cấu hình Kubernetes, ArgoCD Application Manifests, Kyverno Admission Policies và Network Policies để quản trị vòng đời ứng dụng của hệ thống tự chữa lành **CDO-01**.

## 📂 Tổ chức Thư mục GitOps

Để đảm bảo khả năng mở rộng hệ thống theo chuẩn **GitOps & Kustomize Overlays**, cấu trúc thư mục được thiết kế chi tiết như sau:

`	ext
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
├── monitoring/                       # Giám sát & Dashboard (Prometheus Alertmanager configs)
│
└── tests-chaos/                      # 💥 Kịch bản Chaos Testing & Validation (Member 9 phụ trách)
    ├── README.md                     # Hướng dẫn chi tiết chạy chaos tests
    ├── oom-simulator.sh              # Script giả lập lỗi OOMKilled trên pod tenant
    ├── queue-backlog-stress.sh       # Script tạo tải ảo giả lập nghẽn SQS Queue
    ├── network-blockade.sh           # Script giả lập đứt kết nối giữa Worker và AI Engine
    └── SLO_validation_report.md      # Template báo cáo chỉ số SLO và nghiệm thu tự chữa lành
`

---

## 🔒 Quy Định Bảo Mật Cụm EKS (Strict Security Hardening)

Nhóm **Sub-team 3** chịu trách nhiệm cấu hình và thực thi tuyệt đối các quy định bảo mật mạng và chính sách nhập cụm (Admission Policies):

### 1. Phân vùng mạng cô lập (NetworkPolicies)
*   **AI Engine Isolation (i-engine-netpolicy.yaml):** 
    Container AI Engine là tài nguyên nhạy cảm (giao tiếp trực tiếp với AWS Bedrock). Bắt buộc phải khóa cứng NetworkPolicy: block toàn bộ Ingress/Egress từ các namespaces hoặc pods khác, **chỉ cho phép** kết nối Ingress đi vào Port 8080 của AI Engine từ các Pods gán nhãn pp=sqs-worker và pp=webhook-receiver trong namespace self-heal-system.
*   **Webhook Isolation (webhook-netpolicy.yaml):**
    Webhook Receiver mở Port 8443 để tiếp nhận Alert payload. Ingress NetworkPolicy chỉ cho phép traffic đi vào Port này từ cụm IP của Prometheus/Alertmanager (hoặc ingress controller).

### 2. Kyverno Admission Guardrails (
estrict-mutations.yaml)
Hệ thống tự chữa lành có tính năng tự động vá lỗi (Fast Lane), cho phép Worker sửa trực tiếp thông số EKS qua API Client. Để tránh lạm dụng quyền và bảo vệ an toàn hệ thống, cấu hình Kyverno ClusterPolicy bắt buộc phải chặn đứng mọi hành động cập nhật tài nguyên từ Worker, **ngoại trừ** hai thông số duy nhất sau được phép thay đổi:
1.  spec.replicas (Khi scale-up xử lý hàng chờ).
2.  spec.template.spec.containers[*].resources.limits (Khi nâng cấu hình khắc phục lỗi OOMKilled).

Bất kỳ hành động sửa đổi cấu hình K8s nào khác (ví dụ: thay đổi image name, sửa volume, thay đổi port...) do Worker hoặc AI Engine gửi lên EKS API đều sẽ bị Kyverno Admission Controller **từ chối (Block)** ngay lập tức.

---

## 💥 Chaos Testing & Kiểm Thử Độ Bền Bỉ (Member 9)

**Member 9 (QA, Chaos & Validation Lead)** chịu trách nhiệm thiết kế, duy trì và thực thi các bài kiểm thử chaos nằm tại thư mục gitops/tests-chaos/. Các kịch bản chaos bao gồm:

### 1. Giả lập OOMKilled (oom-simulator.sh):
*   Sử dụng container chạy ứng dụng ngốn RAM (như stress-ng) deploy vào namespaces tenant (	enant-payment hoặc 	enant-checkout) nhằm cưỡng ép hệ sinh thái Kubernetes bắn alert PodOOMKilled. 
*   **Mục tiêu validation:** Kiểm tra xem Webhook có lock thành công, SQS nhận tin nhắn và Worker có patch limits x1.5 lần của pod lỗi lên EKS và CodeCommit đúng SLO hay không.

### 2. Mô phỏng SQS Queue Backlog (queue-backlog-stress.sh):
*   Tự động gửi liên tục hàng nghìn alert giả lập vào SQS Queue để tạo backlog lớn.
*   **Mục tiêu validation:** Kiểm tra Prometheus kích hoạt cảnh báo, Worker tự động trigger Argo Workflow để nâng replicas (Slow Lane) khắc phục backlog, và tự động thu hẹp (scale-in) khi hàng chờ trống.

### 3. Đứt kết nối mạng AI Engine (
etwork-blockade.sh):
*   Sử dụng NetworkPolicy tạm thời block cổng 8080 của AI Engine hoặc ngắt giao tiếp của SQS Worker.
*   **Mục tiêu validation:** Thử nghiệm phản ứng của **Circuit Breaker** (phải tự động ngắt mạch sau 3 lần lỗi liên tiếp, chuyển sang trạng thái cảnh báo khẩn cấp lên Slack/SNS để kỹ sư trực vận hành on-call nhảy vào).

---

## 👥 Phân Vai Chi Tiết Trong Sub-team 3 (Member Responsibilities & Deliverables)

Để đảm bảo hiệu quả làm việc nhóm song song và tránh chồng chéo code, các thành viên Sub-team 3 được phân chia trách nhiệm và yêu cầu đầu ra (output) chi tiết như sau:

### 1. **Member 7 (GitOps & Security Policy Lead)**
*   **Trách nhiệm chính:**
    *   Xây dựng cấu trúc thư mục repo gitops/ theo chuẩn Kustomize Base/Overlays.
    *   Thiết lập cấu hình ArgoCD App-of-Apps (Root Application và các Child Applications).
    *   Viết các Kubernetes NetworkPolicies cô lập lưu lượng mạng cho Webhook và AI Engine.
    *   Xây dựng chính sách bảo mật Kyverno ClusterPolicy 
estrict-mutations.yaml khóa quyền API Server.
    *   Xây dựng pipeline gitops-pipeline.yml thực hiện static check (kube-linter/Kubeval) đối với K8s manifests và tự động sync/push code sang AWS CodeCommit repository.
*   **Đầu ra (Deliverables):**
    *   Thư mục gitops/argo-apps/ và gitops/manifests/ hoàn chỉnh chạy được trên ArgoCD.
    *   Tệp cấu hình NetworkPolicies và Kyverno ClusterPolicy.
    *   Mã nguồn CI/CD pipeline gitops-pipeline.yml.
*   **Các file đảm nhiệm:**
    *   gitops/argo-apps/*
    *   gitops/manifests/*
    *   gitops/security-policies/*
    *   .github/workflows/gitops-pipeline.yml

### 2. **Member 8 (Observability & Audit Stream Lead)**
*   **Trách nhiệm chính:**
    *   Triển khai Kube-Prometheus-Stack Helm chart lên cụm EKS.
    *   Cấu hình Alertmanager Routing trỏ webhook về dịch vụ Webhook Receiver.
    *   Xây dựng Prometheus Alert Rules phát hiện các sự cố OOMKilled, SQS Queue Backlog, và Service Stuck.
    *   Phối hợp với Sub-team 1 cấu hình AWS Kinesis Data Firehose để stream logs nghiệp vụ từ SQS Worker ghi thẳng xuống S3 Audit Bucket ở chế độ Object Lock COMPLIANCE.
*   **Đầu ra (Deliverables):**
    *   Helm values file cấu hình Prometheus Operator & Alertmanager.
    *   Tệp định nghĩa Prometheus Alert Rules.
    *   Cấu hình hạ tầng Kinesis Firehose stream logs và IAM Roles liên quan (IRSA).
*   **Các file đảm nhiệm:**
    *   gitops/monitoring/* (Sẽ khởi tạo thư mục này để chứa config Prometheus/Alertmanager)
    *   infra/environments/sandbox/services/ (Khai báo Helm release cho Prometheus)

### 3. **Member 9 (QA, Chaos & Validation Lead)**
*   **Trách nhiệm chính:**
    *   Thiết lập và vận hành các kịch bản Chaos Testing tại môi trường Sandbox.
    *   Phát triển các script giả lập sự cố OOMKilled (stress-ng), spam SQS Queue backlog, và block mạng AI Engine.
    *   Đo lường các chỉ số SLO phục hồi tự động của hệ thống (MTTR < 15 giây đối với Fast Lane, < 120 giây đối với Slow Lane).
    *   Thực hiện kiểm thử E2E tích hợp để kiểm định hoạt động của cơ chế Circuit Breaker (Lỗi 3 lần/giờ kích hoạt SNS cảnh báo khẩn).
    *   Lập Báo cáo Nghiệm thu SLO (SLO Validation Report) chi tiết sau mỗi chu kỳ kiểm thử.
*   **Đầu ra (Deliverables):**
    *   Các shell scripts giả lập sự cố hoàn chỉnh, chạy được trên pods.
    *   Tệp báo cáo SLO chứa kết quả đo đạc thời gian tự chữa lành thực tế.
*   **Các file đảm nhiệm:**
    *   gitops/tests-chaos/*
---

## 🔌 Quy trình giải phóng phụ thuộc & Đấu nối Cluster (Integration & GitOps Steps)

**Sub-team 3** chịu trách nhiệm cài đặt ArgoCD, Prometheus và Kyverno lên cụm EKS. Quy trình xử lý dependencies và đấu nối hệ thống diễn ra như sau:

### 1. Khi chưa có EKS Cluster của Sub-team 1
*   **Vấn đề:** Không có Kubernetes cluster để test YAML manifest, NetworkPolicies và Kyverno policies.
*   **Giải pháp:** 
    *   Tự dựng cụm **Kind** (Kubernetes in Docker) hoặc **Minikube** cục bộ trên máy cá nhân.
    *   Cài đặt ArgoCD và Prometheus Stack lên cụm local để kiểm tra cú pháp YAML, kiểm nghiệm tính năng Admission Control của Kyverno và luồng đồng bộ Argo CD Sync Waves.
    *   Mọi check-in code YAML phải chạy qua pipeline kiểm thử tự động `gitops-pipeline.yml` (sử dụng `kube-linter` và `pluto` để quét lỗi cấu trúc/version API lỗi thời).

### 2. Quy trình đấu nối khi EKS Cluster sẵn sàng
*   **Vấn đề:** Đồng bộ mã nguồn ứng dụng và cấu hình an toàn lên Sandbox EKS.
*   **Giải pháp (Staged Cluster Bootstrap):**
    *   **Bước 1:** Sau khi Sub-team 1 hoàn thành Phase 3 (EKS), Member 7 áp dụng Helm release cài đặt ArgoCD thông qua Data remote state.
    *   **Bước 2:** Đăng ký Repository của AWS CodeCommit vào ArgoCD làm nguồn Manifest chính thống.
    *   **Bước 3:** Khởi tạo ArgoCD Root Application (`root-application.yaml`) để tự động quét thư mục `gitops/argo-apps/` và tạo các ứng dụng con theo đúng thứ tự Sync Waves:
        *   `Wave -4`: Khởi tạo Namespace `self-heal-system` và `observability`.
        *   `Wave -3`: Áp dụng NetworkPolicies và Kyverno ClusterPolicy bảo mật cụm.
        *   `Wave 0`: Tự động pull Docker images từ ECR (do Sub-team 2 build bằng Commit SHA tag) để deploy Webhook và SQS Worker.
---

## 🔒 Override Kyverno Images trong GitOps Manifests

Đối với các ứng dụng triển khai qua file manifest (`gitops/manifests/`), **Member 7** phải kiểm tra toàn bộ file YAML và bảo đảm trường `image` trỏ trực tiếp về AWS ECR Private:

1.  **Kyverno Install YAML:** Sử dụng image mirrored trên ECR Private:
    *   `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/kyverno:v1.12.5`
    *   `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/kyvernopre:v1.12.5`
    *   `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/background-controller:v1.12.5`
    *   `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/cleanup-controller:v1.12.5`
    *   `544011261607.dkr.ecr.us-east-1.amazonaws.com/kyverno/reports-controller:v1.12.5`

2.  **Cách thức kiểm tra (Validation):**
    *   Chạy `git diff` và kiểm tra xem có bất kỳ dòng nào chứa các public domain registry (`ghcr.io`, `quay.io`, `docker.io`, `registry.k8s.io`) hay không.
    *   Nếu có $ightarrow$ Sửa lại đường dẫn thành `544011261607.dkr.ecr.us-east-1.amazonaws.com/<repo>:<tag>`.
