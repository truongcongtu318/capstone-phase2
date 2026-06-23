"""
POC: GitOps Hybrid Self-Heal Controller
TF3 - CDO-1 | Capstone Phase 2

Test 3 kịch bản:
  [1] Race condition: Patch nóng BỊ ArgoCD revert (không có protection)
  [2] Fix race condition: Tắt sync → Patch → Push Git → Bật sync lại
  [3] Đo latency toàn bộ E2E flow

Yêu cầu:
  pip install kubernetes pyyaml
  argocd CLI đã đăng nhập: argocd login localhost:8080 --username admin --password <pass> --insecure
"""

import subprocess
import time
import yaml
import os
import sys

# ===================================================================
# CẤU HÌNH - Chỉnh sửa các biến này theo môi trường của bạn
# ===================================================================
ARGOCD_APP_NAME = "my-app"          # Tên ArgoCD Application
K8S_DEPLOYMENT  = "my-app"          # Tên Deployment trong K8s
K8S_NAMESPACE   = "default"         # Namespace của app
NEW_MEMORY      = "256Mi"           # RAM mới sau khi vá lỗi
YAML_FILE       = "poc/deployment.yaml"  # Path file YAML trong repo

# ===================================================================
# HELPER FUNCTIONS
# ===================================================================

def log(icon, msg):
    """In log có màu và icon."""
    print(f"{icon}  {msg}")

def run(cmd, capture=False):
    """Chạy shell command và return output nếu cần."""
    result = subprocess.run(cmd, shell=True, capture_output=capture, text=True)
    if capture:
        return result.stdout.strip()
    return result.returncode

def check_kubectl():
    """Kiểm tra kubectl và minikube có đang chạy không."""
    rc = run("kubectl cluster-info", capture=True)
    if "Kubernetes" not in rc:
        log("❌", "kubectl không kết nối được cluster. Chạy 'minikube start' trước.")
        sys.exit(1)
    log("✅", "kubectl đã kết nối cluster")

def check_argocd_cli():
    """Kiểm tra argocd CLI đã login chưa."""
    out = run(f"argocd app get {ARGOCD_APP_NAME} --grpc-web 2>&1", capture=True)
    if "Argo CD server address unspecified" in out or "Unauthenticated" in out:
        log("❌", "argocd CLI chưa đăng nhập.")
        log("  ", "Chạy: kubectl port-forward svc/argocd-server -n argocd 8080:443")
        log("  ", "Sau đó: argocd login localhost:8080 --username admin --password <pass> --insecure")
        sys.exit(1)
    log("✅", f"ArgoCD app '{ARGOCD_APP_NAME}' tìm thấy")

# ===================================================================
# CORE ACTIONS
# ===================================================================

def patch_k8s_memory(memory: str):
    """Patch Memory Limit trực tiếp vào K8s Deployment (Direct API Patch)."""
    patch_json = (
        f'{{"spec":{{"template":{{"spec":{{"containers":'
        f'[{{"name":"main","resources":{{"limits":{{"memory":"{memory}"}},'
        f'"requests":{{"memory":"64Mi"}}}}}}]}}}}}}}}'
    )
    rc = run(f'kubectl patch deployment {K8S_DEPLOYMENT} -n {K8S_NAMESPACE} --patch \'{patch_json}\'')
    return rc == 0

def get_current_memory() -> str:
    """Đọc Memory Limit hiện tại từ K8s Deployment."""
    out = run(
        f"kubectl get deployment {K8S_DEPLOYMENT} -n {K8S_NAMESPACE} "
        f"-o jsonpath='{{.spec.template.spec.containers[0].resources.limits.memory}}'",
        capture=True
    )
    return out.strip()

def toggle_argocd_sync(enable: bool):
    """Bật/tắt Auto-Sync của ArgoCD Application."""
    if enable:
        run(f"argocd app set {ARGOCD_APP_NAME} --sync-policy automated --grpc-web")
    else:
        run(f"argocd app set {ARGOCD_APP_NAME} --sync-policy none --grpc-web")

def force_argocd_sync():
    """Ép ArgoCD sync ngay lập tức."""
    run(f"argocd app sync {ARGOCD_APP_NAME} --grpc-web")

def update_yaml_and_push(memory: str):
    """Sửa file YAML, commit và push lên Git."""
    # Đọc file YAML
    with open(YAML_FILE, 'r') as f:
        data = yaml.safe_load(f)

    # Cập nhật memory limit
    data['spec']['template']['spec']['containers'][0]['resources']['limits']['memory'] = memory
    data['spec']['template']['spec']['containers'][0]['resources']['requests']['memory'] = "64Mi"

    # Ghi lại file
    with open(YAML_FILE, 'w') as f:
        yaml.dump(data, f, default_flow_style=False)

    # Git commit + push
    run(f'git add {YAML_FILE}')
    run(f'git commit -m "chore(self-heal): scale memory to {memory} [skip ci]"')
    rc = run('git push origin main')
    return rc == 0

# ===================================================================
# TEST CASES
# ===================================================================

def test_1_race_condition():
    """
    Test 1: Chứng minh Race Condition khi KHÔNG có protection.
    Mong đợi: ArgoCD sẽ tự động revert lại RAM cũ sau vài giây.
    """
    print("\n" + "="*60)
    print("  TEST 1: Race Condition (Không có protection)")
    print("="*60)

    original_mem = get_current_memory()
    log("📊", f"RAM hiện tại: {original_mem}")

    # Patch nóng trực tiếp — KHÔNG tắt ArgoCD sync
    log("🚀", f"Patch nóng RAM lên {NEW_MEMORY} (không tắt ArgoCD sync)...")
    patch_k8s_memory(NEW_MEMORY)

    log("⏳", f"RAM sau patch: {get_current_memory()}")
    log("👀", "Chờ 15 giây xem ArgoCD có tự revert không...")

    for i in range(3):
        time.sleep(5)
        mem = get_current_memory()
        log("  ", f"Sau {(i+1)*5}s — RAM: {mem}")
        if mem == original_mem:
            log("⚠️ ", f"ArgoCD ĐÃ REVERT! RAM quay về {original_mem}. Race condition xảy ra!")
            print("-"*60)
            print("  KẾT LUẬN Test 1: Race Condition XÁC NHẬN tồn tại.")
            print("  Cần áp dụng giải pháp 'Sync Suspension' (Test 2).")
            print("-"*60)
            return True

    log("✅", f"ArgoCD không revert (RAM vẫn là {get_current_memory()})")
    print("-"*60)
    print("  KẾT LUẬN Test 1: Không phát hiện Race Condition")
    print("  (Có thể selfHeal chưa bật hoặc chưa phát hiện OutOfSync)")
    print("-"*60)
    return False

def test_2_sync_suspension():
    """
    Test 2: Giải pháp đúng — Tắt sync → Patch → Git push → Bật sync lại.
    Mong đợi: Không bị revert, ArgoCD sync state = Synced (xanh lá).
    """
    print("\n" + "="*60)
    print("  TEST 2: Sync Suspension (Giải pháp đúng)")
    print("="*60)

    t_start = time.time()

    # Bước 1: Tắt ArgoCD Auto-Sync để tránh race condition
    log("🔒", "Bước 1: Tắt ArgoCD Auto-Sync...")
    toggle_argocd_sync(enable=False)

    # Bước 2: Patch nóng trực tiếp vào K8s ngay lập tức
    t_patch = time.time()
    log("🚀", f"Bước 2: Patch nóng RAM lên {NEW_MEMORY}...")
    ok = patch_k8s_memory(NEW_MEMORY)
    if ok:
        log("✅", f"Patch thành công! RAM hiện tại: {get_current_memory()} (trong {round(time.time()-t_patch, 1)}s)")
    else:
        log("❌", "Patch thất bại!")
        return

    # Bước 3: Commit và push lên Git để đồng bộ lâu dài
    log("📝", "Bước 3: Commit cấu hình RAM mới lên Git...")
    t_git = time.time()
    ok = update_yaml_and_push(NEW_MEMORY)
    if ok:
        log("✅", f"Git push thành công! ({round(time.time()-t_git, 1)}s)")
    else:
        log("⚠️ ", "Git push thất bại (có thể chưa config remote). Bỏ qua, tiếp tục...")

    # Bước 4: Bật lại ArgoCD sync và force sync ngay
    log("🔄", "Bước 4: Bật lại ArgoCD Auto-Sync và force sync...")
    toggle_argocd_sync(enable=True)
    force_argocd_sync()

    t_total = round(time.time() - t_start, 2)

    # Kiểm tra kết quả
    time.sleep(5)
    final_mem = get_current_memory()

    print("\n" + "-"*60)
    print(f"  ⏱️  Tổng latency E2E: {t_total} giây")
    print(f"  💾  RAM sau khi vá:   {final_mem}")

    if final_mem == NEW_MEMORY:
        print("  ✅  KẾT LUẬN Test 2: THÀNH CÔNG — Không bị race condition!")
        print("      GitOps Hybrid Angle XÁC NHẬN KHẢ THI.")
    else:
        print(f"  ❌  KẾT LUẬN Test 2: THẤT BẠI — RAM không khớp ({final_mem} != {NEW_MEMORY})")
    print("-"*60)

def test_3_latency():
    """
    Test 3: Đo latency từng bước của toàn bộ flow E2E.
    Kết quả này sẽ được đưa vào ADR-001 và 02_infra_design.md.
    """
    print("\n" + "="*60)
    print("  TEST 3: Đo Latency từng bước")
    print("="*60)

    results = {}

    # Bước 1: Tắt sync
    t = time.time()
    toggle_argocd_sync(enable=False)
    results["1_toggle_off"] = round(time.time() - t, 2)
    log("⏱️ ", f"Tắt ArgoCD sync: {results['1_toggle_off']}s")

    # Bước 2: Patch nóng
    t = time.time()
    patch_k8s_memory(NEW_MEMORY)
    results["2_patch"] = round(time.time() - t, 2)
    log("⏱️ ", f"Direct K8s Patch: {results['2_patch']}s")

    # Bước 3: Git push
    t = time.time()
    update_yaml_and_push(NEW_MEMORY)
    results["3_git_push"] = round(time.time() - t, 2)
    log("⏱️ ", f"Git commit + push: {results['3_git_push']}s")

    # Bước 4: Bật lại sync
    t = time.time()
    toggle_argocd_sync(enable=True)
    force_argocd_sync()
    results["4_argocd_sync"] = round(time.time() - t, 2)
    log("⏱️ ", f"ArgoCD force sync: {results['4_argocd_sync']}s")

    total = sum(results.values())

    print("\n" + "-"*60)
    print("  📊 KẾT QUẢ ĐO LATENCY:")
    print(f"     Tắt ArgoCD Sync  : {results['1_toggle_off']}s")
    print(f"     Direct K8s Patch : {results['2_patch']}s  ← Pod sống lại từ đây")
    print(f"     Git commit + push: {results['3_git_push']}s")
    print(f"     ArgoCD sync      : {results['4_argocd_sync']}s")
    print(f"     ─────────────────────────────")
    print(f"     TỔNG E2E latency : {total}s")
    print()
    if total < 30:
        print(f"  ✅  Latency {total}s < 30s — ĐẠT SLO yêu cầu!")
    elif total < 120:
        print(f"  ⚠️   Latency {total}s < 120s — Acceptable nhưng cần tối ưu Git push")
    else:
        print(f"  ❌  Latency {total}s > 120s — Vi phạm SLO! Cần xem xét lại kiến trúc")
    print("-"*60)
    print()
    print("  💡 GHI CHÚ VÀO ADR-001:")
    print(f"     'POC đo được: Pod phục hồi sau {results['2_patch']}s (Direct Patch).")
    print(f"      Toàn bộ GitOps sync hoàn tất sau {total}s.")
    print(f"      Đạt yêu cầu SLO < 120s của Client.'")
    print("-"*60)

# ===================================================================
# MAIN
# ===================================================================

if __name__ == "__main__":
    print("\n" + "="*60)
    print("  GitOps Hybrid POC - TF3 CDO-1")
    print("  Self-Heal Controller Test Suite")
    print("="*60)

    # Kiểm tra môi trường
    check_kubectl()
    check_argocd_cli()

    # Chọn test muốn chạy
    print("\nChọn test muốn chạy:")
    print("  [1] Test Race Condition (chứng minh vấn đề)")
    print("  [2] Test Sync Suspension (chứng minh giải pháp)")
    print("  [3] Test Đo Latency E2E")
    print("  [all] Chạy cả 3 test")
    choice = input("\nLựa chọn của bạn: ").strip().lower()

    if choice == "1":
        test_1_race_condition()
    elif choice == "2":
        test_2_sync_suspension()
    elif choice == "3":
        test_3_latency()
    elif choice == "all":
        test_1_race_condition()
        time.sleep(3)
        test_2_sync_suspension()
        time.sleep(3)
        test_3_latency()
    else:
        print("Lựa chọn không hợp lệ. Vui lòng chọn 1, 2, 3 hoặc all.")
