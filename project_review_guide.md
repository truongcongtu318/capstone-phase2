# Tài Liệu Ôn Tập Kiến Thức & Vận Hành Dự Án (EKS - GitOps - AWS)

Tài liệu này được biên soạn nhằm giúp bạn hệ thống lại toàn bộ kiến thức, các lỗi đã gặp, cách giải quyết và các lệnh vận hành thực tế đã thực hiện trong dự án (đặc biệt phù hợp cho các buổi báo cáo với Leader/Sếp hoặc chuẩn bị cho các đợt review).

---

## 🎯 Phần 1: Tổng Quan Kiến Trúc & Luồng Đi Của Code
*   **Source Code (GitOps):** Được lưu trữ trên **AWS CodeCommit** (dịch vụ Git riêng tư của AWS).
*   **Kubernetes Cluster:** Chạy trên dịch vụ **AWS EKS (Elastic Kubernetes Service)**.
*   **GitOps Agent:** Sử dụng **ArgoCD** để tự động đồng bộ (sync) các thay đổi từ CodeCommit vào trong Cluster.
*   **Networking:** EKS cluster nằm trong VPC private, kết nối tới AWS CodeCommit thông qua **VPC Endpoints** (`git-codecommit` và `codecommit` dạng Interface) để đảm bảo traffic không đi ra ngoài internet công cộng.

---

## 🔐 Phần 2: Cơ Chế Phân Quyền EKS IRSA (IAM Roles for Service Accounts)
Để ArgoCD trong EKS có thể kéo code từ CodeCommit (nằm ngoài K8s nhưng cùng tài khoản AWS), chúng ta sử dụng cơ chế **IRSA**.

### 1. Cách thức hoạt động:
1.  **OIDC Provider:** EKS Cluster liên kết với một OIDC (OpenID Connect) Provider trên AWS IAM.
2.  **IAM Role:** Tạo một IAM Role có chính sách (Policy) cho phép pull code: `codecommit:GitPull`.
3.  **Trust Relationship (Quan hệ tin cậy):** Cấu hình chỉ cho phép đúng tài khoản dịch vụ của ArgoCD (`system:serviceaccount:argocd:argocd-repo-server`) được phép giả định Role này (`AssumeRoleWithWebIdentity`).
4.  **ServiceAccount Annotation:** Gắn nhãn (annotate) cho Kubernetes ServiceAccount tên của IAM Role đó.
5.  **EKS Pod Identity Webhook:** Tự động phát hiện annotation trên ServiceAccount, sau đó tự động tiêm (inject) 2 biến môi trường và file token vào trong Pod:
    *   `AWS_ROLE_ARN` (tên Role)
    *   `AWS_WEB_IDENTITY_TOKEN_FILE` (chìa khóa xác thực tạm thời)

---

## 🛠️ Phần 3: Lịch Sử Troubleshoot Xác Thực ArgoCD & CodeCommit

### Vấn đề 1: Lỗi `Unknown` hoặc `Sync Failed` (Mới bắt đầu)
*   **Hiện tượng:** Các ứng dụng trên ArgoCD Dashboard báo màu xám/đỏ.
*   **Nguyên nhân:** `argocd-repo-server` chưa được cấu hình ServiceAccount có gắn IAM Role (IRSA), dẫn đến việc CodeCommit từ chối truy cập.
*   **Giải pháp:** Cập nhật file yaml/annotate ServiceAccount và restart pod.

### Vấn đề 2: Lỗi `401 Unauthorized` từ kubectl
*   **Hiện tượng:** Gõ lệnh `kubectl` báo lỗi `You must be logged in to the server...`.
*   **Nguyên nhân:** Phiên đăng nhập AWS SSO (Single Sign-On) ở máy local bị hết hạn hoặc chọn nhầm Role không có quyền Admin (ví dụ chọn `PowerUserAccess` thay vì `AdministratorAccess` - EKS yêu cầu quyền admin của người tạo cluster hoặc quyền được map cụ thể).
*   **Giải pháp:** Đăng nhập lại qua AWS SSO và export 3 biến môi trường AWS Admin (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).

### Vấn đề 3: Lỗi `SPNEGO token required` của ArgoCD
*   **Hiện tượng:** Đã gắn IRSA thành công nhưng ArgoCD vẫn báo lỗi `SPNEGO token required`.
*   **Nguyên nhân gốc rễ:** 
    *   Mặc định ArgoCD dùng thư viện Go (`go-git`) để clone. Thư viện này không tự động gọi AWS SDK để lấy thông tin đăng nhập từ token IRSA, mà cố tình clone ẩn danh (Anonymous).
    *   Để khắc phục, ta khai báo một Kubernetes Secret dạng Repo credential. Khi có Secret này, ArgoCD sẽ sử dụng thông tin xác thực để kết nối.
*   **Giải pháp:** Tạo Kubernetes Secret loại `repository` chứa `username` và `password` được tính toán động từ AWS Temporary Credentials (chạy script Python/AWS CLI để tạo).

### Vấn đề 4: Token AWS bị kẹt ngoài Pod (`automountServiceAccountToken: false`)
*   **Hiện tượng:** Đã annotate ServiceAccount nhưng Pod vẫn không có các biến môi trường `AWS_ROLE_ARN`.
*   **Nguyên nhân:** ArgoCD cấu hình mặc định tắt tự động mount token (`automountServiceAccountToken: false`).
*   **Giải pháp:** Patch deployment/ServiceAccount của `argocd-repo-server` chuyển thuộc tính này thành `true` và rollout restart.

---

## 🛡️ Phần 4: Chính Sách Bảo Mật & Phân Quyền (Kyverno & RBAC)
Dự án áp dụng mô hình bảo mật nhiều lớp (Defense in Depth) đối với tác vụ tự chữa lành (Self-Healing):

### 1. Phân quyền RBAC (Kubernetes native):
*   Tạo `ClusterRole` chỉ cho phép đọc và sửa đổi (`get, list, watch, update, patch`) các resource cơ bản: Deployment, StatefulSet, ConfigMap, HPA.
*   Dùng `RoleBinding` chỉ giới hạn quyền này trong 2 namespace của Tenant: `tenant-payment` và `tenant-checkout`. 
*   **Ý nghĩa:** Dù script self-heal có bị chiếm quyền, nó cũng KHÔNG THỂ phá hoại hệ thống ở các namespace như `kube-system`, `argocd` hay `observability`.

### 2. Chính sách Kyverno (`ClusterPolicy`):
*   **Rule 1 (Deny Dangerous Fields):** Cấm mọi hành vi chỉnh sửa các cấu hình nguy hiểm như: bật `privileged: true` cho container, mount `hostPath` (truy cập ổ cứng node), đổi container image, sửa env, command, ports,... Ngoại trừ ArgoCD controller được phép làm.
*   **Rule 2 (Only Self-Heal Can Patch):** Chỉ duy nhất ServiceAccount `self-heal-executor` và ArgoCD được phép thực hiện cập nhật resources trên namespace của tenant.
*   **Rule 3 (Deny System Namespace Mutation):** Chặn tuyệt đối `self-heal-executor` sửa đổi hay xoá bất kỳ tài nguyên nào trong namespace hệ thống (`argocd`, `observability`).

*Note: Lý do Kyverno báo lỗi đỏ `CRD not found` trên ArgoCD hiện tại là vì Cluster chưa cài đặt Kyverno Operator.*

---

## ☸️ Phần 5: Tự Động Co Giãn Node Với Karpenter
Để tối ưu hóa chi phí và tốc độ mở rộng tài nguyên (node) cho EKS cluster, dự án sử dụng **Karpenter** thay vì Cluster Autoscaler truyền thống.

### 1. Cơ chế hoạt động của Karpenter trong dự án:
*   **Controller Role (IRSA):** Karpenter controller chạy dưới dạng một Pod trong namespace `karpenter` với ServiceAccount tên `karpenter`.
    *   Tương tự như ArgoCD, nó được gán quyền thông qua IRSA bằng vai trò `${var.name_prefix}-karpenter-controller-role`.
    *   Quyền hạn này cho phép controller gọi trực tiếp các API của AWS EC2 để tự động khởi tạo (`ec2:RunInstances`, `ec2:CreateFleet`) hoặc giải phóng (`ec2:TerminateInstances`) các máy chủ EC2 một cách nhanh chóng khi phát hiện có Pod ở trạng thái `Pending` do thiếu tài nguyên.
*   **Node Role & Instance Profile:**
    *   Khi Karpenter tự động khởi chạy một EC2 instance mới để làm worker node cho EKS, instance đó sẽ được gắn IAM Role `${var.name_prefix}-karpenter-node-role` thông qua Instance Profile `${var.name_prefix}-karpenter-node-profile`.
    *   Role này được cấp sẵn các quyền tiêu chuẩn của AWS để Worker Node giao tiếp được với EKS Control Plane:
        *   `AmazonEKSWorkerNodePolicy` (cho phép node kết nối vào cụm EKS).
        *   `AmazonEKS_CNI_Policy` (cấp phát IP cho Pod thông qua VPC CNI).
        *   `AmazonEC2ContainerRegistryReadOnly` (đọc và kéo image từ AWS ECR).
        *   `AmazonSSMManagedInstanceCore` (cho phép quản lý, truy cập shell từ xa vào node an toàn qua AWS Systems Manager Session Manager).

---

## 💻 Phần 6: Cheat-Sheet Các Câu Lệnh Vận Hành Cần Nhớ

### 1. Đăng nhập AWS SSO & Cập nhật Kubeconfig
```bash
# 1. Đăng nhập SSO (nếu token hết hạn)
aws configure sso

# 2. Cập nhật Kubeconfig trỏ vào cluster EKS ở region us-east-1
aws eks update-kubeconfig --region us-east-1 --name tf3-cdo1-sandbox-eks
```

### 2. Sửa lỗi mount token cho ArgoCD Repo Server
```bash
# Cho phép tự động mount token
kubectl patch deployment argocd-repo-server -n argocd --type=json -p='[{"op": "replace", "path": "/spec/template/spec/automountServiceAccountToken", "value": true}]'

# Restart Pod
kubectl rollout restart deployment argocd-repo-server -n argocd
```

### 3. Tạo Secret đồng bộ CodeCommit ngắn hạn (Hạn dùng ~1 tiếng theo phiên SSO)
Chạy script Python để sinh credentials động và ghi vào Secret:
```bash
eval $(python3 << 'PYEOF'
import hashlib, hmac, datetime, os, urllib.parse, sys
ak = os.environ.get('AWS_ACCESS_KEY_ID', '')
sk = os.environ.get('AWS_SECRET_ACCESS_KEY', '')
st = os.environ.get('AWS_SESSION_TOKEN', '')
if not all([ak, sk]):
    print("echo 'ERROR: Thiet lap thieu AWS Credentials trong env!'", file=sys.stderr)
    sys.exit(1)
region = 'us-east-1'
dt = datetime.datetime.utcnow().strftime('%Y%m%dT%H%M%S')
def sign(key, msg):
    k = key if isinstance(key, bytes) else key.encode()
    return hmac.new(k, msg.encode(), hashlib.sha256).digest()
k = sign(sign(sign(sign(f'AWS4{sk}', dt[:8]), region), 'codecommit'), 'aws4_request')
sts_str = f'GIT\n{dt}\n{dt[:8]}/{region}/codecommit/aws4_request'
sig = hmac.new(k, sts_str.encode(), hashlib.sha256).hexdigest()
enc = urllib.parse.quote(st, safe='') if st else ''
pwd = f'{dt}Z{enc}Z{sig}' if st else f'{dt}Z{sig}'
print(f'export CC_USER="{ak}"')
print(f'export CC_PASS="{pwd}"')
PYEOF
)

# Áp dụng Secret vào cluster
kubectl delete secret codecommit-repo -n argocd 2>/dev/null
kubectl create secret generic codecommit-repo \
  -n argocd \
  --from-literal="type=git" \
  --from-literal="url=https://git-codecommit.us-east-1.amazonaws.com/v1/repos/tf3-cdo1-sandbox-gitops" \
  --from-literal="username=$CC_USER" \
  --from-literal="password=$CC_PASS"
kubectl label secret codecommit-repo -n argocd argocd.argoproj.io/secret-type=repository --overwrite
```

### 4. Port forward để truy cập ArgoCD UI
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Truy cập: https://localhost:8080 (Bỏ qua cảnh báo SSL)
```

