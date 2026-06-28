from __future__ import annotations

import json, logging, os, subprocess, tempfile, time
from dataclasses import dataclass, field
from typing import Any

import yaml

log = logging.getLogger(__name__)

# ── Env / Constants ──────────────────────────────────────────────────────────
ARGOCD_URL    = os.getenv("ARGOCD_SERVER_URL", "http://argocd-server.argocd.svc.cluster.local")
ARGOCD_TOKEN  = os.getenv("ARGOCD_AUTH_TOKEN", "")
CC_REPO       = os.getenv("CODECOMMIT_REPO_URL", "")
CC_BRANCH     = os.getenv("CODECOMMIT_BRANCH", "main")
GIT_NAME      = os.getenv("GIT_AUTHOR_NAME",  "cdo-self-heal-bot")
GIT_EMAIL     = os.getenv("GIT_AUTHOR_EMAIL", "cdo-bot@internal.local")
ALLOWED_NS    = {"tenant-payment", "tenant-checkout"}   # RBAC boundary §IV

# ── Data Classes ─────────────────────────────────────────────────────────────
@dataclass
class PreStateSnapshot:
    """Trạng thái trước khi vá — dùng để rollback nếu verify thất bại."""
    pattern_type: str        # "urgent" | "deferred"
    namespace: str
    deployment_name: str
    # Fast Lane (urgent)
    memory_limit_mb:   int | None = None
    memory_request_mb: int | None = None
    cpu_limit:         str | None = None
    replicas:          int | None = None
    container_name:    str | None = None
    # Slow Lane (deferred)
    git_commit_sha:    str | None = None


@dataclass
class ExecutionResult:
    """Kết quả trả về sau execute() hoặc rollback() — gửi sang audit_logger."""
    action:                  str
    target:                  str
    status:                  str   # "COMPLETED" | "FAILED" | "DRY_RUN"
    execution_time_seconds:  float
    dry_run:                 bool = False
    error:                   str | None = None
    details:                 dict[str, Any] = field(default_factory=dict)


# ── Guards ───────────────────────────────────────────────────────────────────
def _guard_ns(ns: str) -> None:
    """Chặn mọi thao tác ra ngoài namespace cho phép (RBAC §IV)."""
    if ns not in ALLOWED_NS:
        raise PermissionError(f"Namespace {ns!r} ngoài RBAC boundary {ALLOWED_NS}")


# ── ArgoCD helpers ───────────────────────────────────────────────────────────
def _argocd(method: str, path: str, body: dict | None = None, dry_run: bool = False) -> None:
    """Gọi ArgoCD REST API. Nếu dry_run=True chỉ log."""
    if dry_run:
        log.info("[DRY_RUN] argocd %s %s", method.upper(), path); return
    import httpx
    url = f"{ARGOCD_URL}{path}"
    headers = {"Authorization": f"Bearer {ARGOCD_TOKEN}", "Content-Type": "application/json"}
    resp = getattr(httpx, method)(url, json=body or {}, headers=headers, timeout=15.0)
    resp.raise_for_status()
    log.info("argocd %s %s → %s", method.upper(), path, resp.status_code)


def _argocd_suspend(app: str, dry_run: bool) -> None:
    """Tắt ArgoCD auto-sync (set manual) TRƯỚC khi patch K8s."""
    _argocd("patch", f"/api/v1/applications/{app}",
            {"spec": {"syncPolicy": {"automated": None}}}, dry_run)


def _argocd_resume(app: str, dry_run: bool) -> None:
    """Bật lại auto-sync + force sync SAU khi patch K8s."""
    _argocd("patch", f"/api/v1/applications/{app}",
            {"spec": {"syncPolicy": {"automated": {"prune": True, "selfHeal": True}}}}, dry_run)
    _argocd("post", f"/api/v1/applications/{app}/sync", dry_run=dry_run)


# ── K8s helpers ──────────────────────────────────────────────────────────────
def _k8s():
    """Trả về AppsV1Api client dùng in-cluster config (IRSA). Fallback kubeconfig khi local."""
    from kubernetes import client as kc, config as cfg
    try: cfg.load_incluster_config()
    except Exception: cfg.load_kube_config()
    return kc.AppsV1Api()


def _read_deployment(ns: str, name: str) -> dict:
    """Đọc replicas + resources của container đầu tiên từ K8s API."""
    dep = _k8s().read_namespaced_deployment(name=name, namespace=ns)
    c   = (dep.spec.template.spec.containers or [None])[0]
    lim = (c.resources.limits  or {}) if c and c.resources else {}
    req = (c.resources.requests or {}) if c and c.resources else {}
    return {
        "replicas":       dep.spec.replicas,
        "container_name": c.name if c else None,
        "memory_limit":   lim.get("memory"),
        "memory_request": req.get("memory"),
        "cpu_limit":      lim.get("cpu"),
    }


def _mi(value: str | None) -> int | None:
    """Parse K8s memory string → MB.  "512Mi"→512, "2Gi"→2048, "1G"→1000, None→None."""
    if not value: return None
    v = value.strip()
    if v.endswith("Gi"): return int(float(v[:-2]) * 1024)
    if v.endswith("Mi"): return int(v[:-2])
    if v.endswith("Ki"): return max(1, int(v[:-2]) // 1024)
    if v.endswith("G"):  return int(float(v[:-1]) * 1000)   # bare G (decimal)
    if v.endswith("M"):  return int(v[:-1])                 # bare M (decimal)
    return None


def _k8s_mem(mb: int) -> str:
    return f"{mb}Mi"


def _patch_body(action: str, params: dict, container: str) -> dict:
    """
    Xây patch body JSON cho K8s PATCH API theo action enum.

    Supported actions:
      PATCH_MEMORY_LIMIT → cập nhật resources.limits/requests.memory
      SCALE_REPLICAS     → cập nhật spec.replicas
      RESTART_DEPLOYMENT → rolling restart qua annotation
    """
    if action == "PATCH_MEMORY_LIMIT":
        ml = params.get("memory_limit_mb")
        if not ml: raise ValueError("PATCH_MEMORY_LIMIT cần 'memory_limit_mb'")
        res: dict = {"limits": {"memory": _k8s_mem(ml)}}
        if mr := params.get("memory_request_mb"):
            res["requests"] = {"memory": _k8s_mem(mr)}
        return {"spec": {"template": {"spec": {"containers": [{"name": container, "resources": res}]}}}}

    if action == "SCALE_REPLICAS":
        r = params.get("replicas")
        if r is None: raise ValueError("SCALE_REPLICAS cần 'replicas'")
        return {"spec": {"replicas": int(r)}}

    if action == "RESTART_DEPLOYMENT":
        return {"spec": {"template": {"metadata": {"annotations":
                {"cdo.self-heal/restart-at": str(int(time.time()))}}}}}

    raise ValueError(f"Action không hỗ trợ: {action!r}")


def _k8s_patch(ns: str, name: str, body: dict, dry_run: bool) -> None:
    """Thực thi K8s patch với ArgoCD suspend/resume bao quanh."""
    app = f"{ns}-app"
    _argocd_suspend(app, dry_run)
    try:
        if dry_run:
            log.info("[DRY_RUN] k8s patch deployment=%s ns=%s body=%s", name, ns, json.dumps(body))
        else:
            _k8s().patch_namespaced_deployment(name=name, namespace=ns, body=body)
            log.info("k8s_patch_applied deployment=%s ns=%s", name, ns)
    finally:
        # Luôn resume — kể cả khi patch lỗi (failsafe §IV)
        _argocd_resume(app, dry_run)


# ── Git helpers ───────────────────────────────────────────────────────────────
def _git(args: list[str], cwd: str | None = None) -> str:
    """Chạy git command, trả stdout, raise nếu thất bại."""
    r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    if r.returncode: raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def _git_clone_and_setup(tmpdir: str) -> str:
    """Clone CodeCommit repo vào tmpdir, cấu hình author. Trả path repo."""
    repo = os.path.join(tmpdir, "repo")
    _git(["clone", CC_REPO, repo])
    _git(["config", "user.name",  GIT_NAME],  cwd=repo)
    _git(["config", "user.email", GIT_EMAIL], cwd=repo)
    return repo


def _values_file(repo: str, ns: str, dep: str) -> str:
    """Tìm values.yaml theo convention gitops/<ns>/<dep>/values.yaml."""
    for path in [
        f"{repo}/gitops/{ns}/{dep}/values.yaml",
        f"{repo}/gitops/{ns}/{dep}.yaml",
        f"{repo}/apps/{ns}/{dep}/values.yaml",
    ]:
        if os.path.exists(path): return path
    raise FileNotFoundError(f"Không tìm thấy values file cho {ns}/{dep}")


def _apply_yaml(file: str, action: str, params: dict) -> None:
    """Sửa values.yaml theo action rồi ghi lại file."""
    with open(file) as f: data = yaml.safe_load(f) or {}

    if action == "PATCH_MEMORY_LIMIT":
        r = data.setdefault("resources", {})
        if ml := params.get("memory_limit_mb"):
            r.setdefault("limits", {})["memory"] = _k8s_mem(ml)
        if mr := params.get("memory_request_mb"):
            r.setdefault("requests", {})["memory"] = _k8s_mem(mr)
    elif action == "SCALE_REPLICAS":
        # Fallback về giá trị hiện tại trong YAML nếu params không có replicas
        data["replicaCount"] = int(params.get("replicas", data.get("replicaCount", 1)))
    else:
        raise ValueError(f"Slow Lane không hỗ trợ action: {action!r}")

    with open(file, "w") as f: yaml.dump(data, f, default_flow_style=False, allow_unicode=True)


def _git_commit_push(repo: str, file: str, msg: str) -> str:
    """Stage file → commit → push. Trả SHA mới."""
    _git(["add", file], cwd=repo)
    _git(["commit", "-m", msg], cwd=repo)
    _git(["push", "origin", CC_BRANCH], cwd=repo)
    return _git(["rev-parse", "HEAD"], cwd=repo)


# ── PUBLIC API ────────────────────────────────────────────────────────────────

def capture_pre_state(decide_response: dict, dry_run: bool = False) -> PreStateSnapshot:
    """
    Snapshot trạng thái hiện tại TRƯỚC khi vá để có thể rollback nếu cần.

    urgent   → đọc K8s API (memory_limit, replicas, container_name).
    deferred → lấy git HEAD SHA từ CodeCommit.
    dry_run  → trả snapshot giả, không gọi API.
    """
    step   = (decide_response.get("action_plan") or [{}])[0]
    params = step.get("params", {})
    ns     = params.get("namespace", "")
    dep    = step.get("target", "").replace("deployment/", "")
    _guard_ns(ns)

    if decide_response.get("pattern_type") == "deferred":
        if dry_run or not CC_REPO:
            sha = "mock-sha-" + str(int(time.time()))
        else:
            with tempfile.TemporaryDirectory(prefix="cdo-sha-") as tmp:  # tự cleanup
                repo = os.path.join(tmp, "repo")
                _git(["clone", "--depth", "1", CC_REPO, repo])
                sha = _git(["rev-parse", "HEAD"], cwd=repo)
        log.info("pre_state_captured deferred ns=%s sha=%s", ns, sha)
        return PreStateSnapshot("deferred", ns, dep, git_commit_sha=sha)

    # urgent
    if dry_run:
        return PreStateSnapshot("urgent", ns, dep,
                                memory_limit_mb=256, memory_request_mb=256,
                                replicas=2, container_name=params.get("container", "app"))
    s = _read_deployment(ns, dep)
    snap = PreStateSnapshot("urgent", ns, dep,
                            memory_limit_mb=_mi(s["memory_limit"]),
                            memory_request_mb=_mi(s["memory_request"]),
                            cpu_limit=s["cpu_limit"],
                            replicas=s["replicas"],
                            container_name=s["container_name"])
    log.info("pre_state_captured urgent ns=%s dep=%s mem=%sMi rep=%s",
             ns, dep, snap.memory_limit_mb, snap.replicas)
    return snap



def execute(decide_response: dict, correlation_id: str, dry_run: bool = False) -> ExecutionResult:
    """
    Thực thi action plan từ /v1/decide.

    Fast Lane (urgent):
      suspend ArgoCD → K8s patch → resume ArgoCD  (RTO < 60s)

    Slow Lane (deferred):
      clone CodeCommit → sửa YAML → commit/push → ArgoCD tự sync
    """
    step   = (decide_response.get("action_plan") or [])
    matched_runbook = decide_response.get("matched_runbook", "UnknownRunbook")
    t0     = time.monotonic()

    log.info("execute_start correlation_id=%s pattern_type=%s runbook=%s dry_run=%s",
             correlation_id, decide_response.get("pattern_type"), matched_runbook, dry_run)

    try:
        if not step: raise ValueError("action_plan rỗng")
        s      = step[0]
        action = s.get("action", "")
        target = s.get("target", "")
        params = s.get("params", {})
        ns     = params.get("namespace", "")
        dep    = target.replace("deployment/", "")
        cont   = params.get("container", "")
        _guard_ns(ns)

        if decide_response.get("pattern_type") == "deferred":
            # Slow Lane
            git_sha = None
            if dry_run:
                log.info("[DRY_RUN] slow_lane action=%s ns=%s dep=%s", action, ns, dep)
            else:
                if not CC_REPO: raise EnvironmentError("CODECOMMIT_REPO_URL chưa set")
                with tempfile.TemporaryDirectory(prefix="cdo-slow-") as tmp:
                    repo  = _git_clone_and_setup(tmp)
                    vfile = _values_file(repo, ns, dep)
                    _apply_yaml(vfile, action, params)
                    git_sha = _git_commit_push(repo, vfile,
                              f"chore(self-heal): [{correlation_id[:8]}] {action} on {ns}/{dep}")
                    log.info("slow_lane_committed sha=%s corr=%s", git_sha, correlation_id)
        else:
            # Fast Lane
            git_sha = None
            body = _patch_body(action, params, cont)
            _k8s_patch(ns, dep, body, dry_run)

        elapsed = time.monotonic() - t0
        log.info("execute_done correlation_id=%s status=%s elapsed=%.2fs",
                 correlation_id, "DRY_RUN" if dry_run else "COMPLETED", elapsed)

        details: dict = {"namespace": ns, "params": params}
        if git_sha:
            details["git_sha"] = git_sha

        return ExecutionResult(action, target,
                               "DRY_RUN" if dry_run else "COMPLETED",
                               elapsed, dry_run,
                               details=details)

    except Exception as exc:
        log.error("execute_FAILED corr=%s error=%s", correlation_id, exc)
        return ExecutionResult(
            step[0].get("action", "UNKNOWN") if step else "UNKNOWN",
            step[0].get("target", "")        if step else "",
            "FAILED", time.monotonic() - t0, dry_run, error=str(exc))


def rollback(snapshot: PreStateSnapshot, correlation_id: str, dry_run: bool = False) -> ExecutionResult:
    """
    Khôi phục về trạng thái trước khi vá.

    urgent   → patch K8s về giá trị cũ trong snapshot (với ArgoCD suspend/resume).
    deferred → git revert commit đã tạo bởi self-heal.
    """
    log.warning("rollback_start pattern=%s ns=%s dep=%s corr=%s",
                snapshot.pattern_type, snapshot.namespace, snapshot.deployment_name, correlation_id)
    t0 = time.monotonic()

    try:
        _guard_ns(snapshot.namespace)

        if snapshot.pattern_type == "urgent":
            body: dict = {}
            if snapshot.replicas is not None:
                body.setdefault("spec", {})["replicas"] = snapshot.replicas
            if snapshot.memory_limit_mb and snapshot.container_name:
                res: dict = {"limits": {"memory": _k8s_mem(snapshot.memory_limit_mb)}}
                if snapshot.memory_request_mb:
                    res["requests"] = {"memory": _k8s_mem(snapshot.memory_request_mb)}
                if snapshot.cpu_limit:
                    res["limits"]["cpu"] = snapshot.cpu_limit
                body.setdefault("spec", {}).setdefault("template", {}) \
                    .setdefault("spec", {})["containers"] = \
                    [{"name": snapshot.container_name, "resources": res}]
            if not body: raise ValueError("Snapshot không có field nào để rollback")
            _k8s_patch(snapshot.namespace, snapshot.deployment_name, body, dry_run)
            details = {"restored_memory_limit_mb": snapshot.memory_limit_mb,
                       "restored_replicas":        snapshot.replicas}

        else:  # deferred
            if not snapshot.git_commit_sha:
                raise ValueError("Slow Lane rollback cần git_commit_sha trong snapshot")
            if not dry_run:
                if not CC_REPO: raise EnvironmentError("CODECOMMIT_REPO_URL chưa set")
                with tempfile.TemporaryDirectory(prefix="cdo-rb-") as tmp:  # tự cleanup
                    repo = _git_clone_and_setup(tmp)
                    # git revert TỰ tạo commit → chỉ cần push, không add/commit thêm
                    _git(["revert", "--no-edit", snapshot.git_commit_sha], cwd=repo)
                    _git(["push", "origin", CC_BRANCH], cwd=repo)
                    new_sha = _git(["rev-parse", "HEAD"], cwd=repo)
                    log.info("rollback_reverted old=%s new=%s", snapshot.git_commit_sha, new_sha)
            else:
                log.info("[DRY_RUN] rollback_slow_lane revert sha=%s", snapshot.git_commit_sha)
            details = {"reverted_to": snapshot.git_commit_sha}

        return ExecutionResult("ROLLBACK", f"deployment/{snapshot.deployment_name}",
                               "DRY_RUN" if dry_run else "COMPLETED",
                               time.monotonic() - t0, dry_run, details=details)

    except Exception as exc:
        log.error("rollback_FAILED corr=%s error=%s", correlation_id, exc)
        return ExecutionResult("ROLLBACK", f"deployment/{snapshot.deployment_name}",
                               "FAILED", time.monotonic() - t0, dry_run, error=str(exc))