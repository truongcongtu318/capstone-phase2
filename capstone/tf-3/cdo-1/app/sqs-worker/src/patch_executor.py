# 🛠️ K8s Patch & CodeCommit Git Executor
# TODO: Triển khai Dual Execution Path:
# 1. Fast Lane (Direct Patch): Dùng K8s Python Client vá nóng limits/replicas -> gọi API tắt auto-sync ArgoCD -> Commit file yaml mới lên AWS CodeCommit -> bật lại auto-sync ArgoCD.
# 2. Slow Lane (GitOps Commit): Gọi Argo Workflow để commit cấu hình thay đổi lên AWS CodeCommit.
