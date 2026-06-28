"""
security.py — SOC2 Compliance Log Scrubbing Middleware (Owner: M6)
CDO-01 · TF3 Self-Heal Engine · webhook-receiver (shared with sqs-worker)

Responsibilities:
  - Tìm và thay thế PII / secrets / credentials bằng "[SCRUBBED]" trước khi:
    1. Ghi log ra console / file.
    2. Đẩy telemetry payload vào SQS.
    3. Ghi audit record vào Kinesis Firehose.

Constraints (project-rules.md §V.2, SUBTEAM2_WORKING_DOC §3.2):
  - 7 loại pattern: AWS Access Key, AWS Secret Key, Bearer JWT,
    Basic Auth, Email, Password fields, Credit Card numbers.
  - Không được scrub nhầm dữ liệu thường (tránh false positive quá mức).
  - Hàm scrub() phải idempotent — gọi nhiều lần không làm hỏng dữ liệu.
"""

from __future__ import annotations

import re
import logging
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# SCRUBBING PATTERNS (7 loại theo SUBTEAM2_WORKING_DOC §3.2)
# ---------------------------------------------------------------------------

SCRUB_REPLACEMENT = "[SCRUBBED]"

# 1. AWS Access Key ID — bắt đầu bằng AKIA, ASIA, hoặc AIDA + 16 ký tự alphanum
_RE_AWS_ACCESS_KEY = re.compile(
    r"\b(A[SK]IA|AIDA)[A-Z0-9]{16}\b"
)

# 2. AWS Secret Access Key — 40 ký tự base64-like đi sau dấu phân cách phổ biến
_RE_AWS_SECRET_KEY = re.compile(
    r"""(?<=[=:"\s])[A-Za-z0-9/+=]{40}(?=["\s,}\]']|$)"""
)

# 3. Bearer JWT Token — "Bearer " + 3-part dot-separated base64
_RE_BEARER_TOKEN = re.compile(
    r"\bBearer\s+[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_.+/=]*",
    re.IGNORECASE,
)

# 4. HTTP Basic Auth — "Basic " + base64 block (ít nhất 8 ký tự)
_RE_BASIC_AUTH = re.compile(
    r"\bBasic\s+[A-Za-z0-9+/=]{8,}",
    re.IGNORECASE,
)

# 5. Email addresses — đơn giản nhưng đủ chính xác cho log scrubbing
_RE_EMAIL = re.compile(
    r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"
)

# 6. Password fields — key-value pairs chứa "password", "passwd", "pwd", "secret"
#    Hỗ trợ JSON ("password": "xxx"), env (PASSWORD=xxx), YAML (password: xxx)
_RE_PASSWORD_FIELD = re.compile(
    r"""(?i)(["']?(?:password|passwd|pwd|secret_?key|api_?key|token|auth_?token)["']?\s*[:=]\s*)(["']?)([^"'\s,}{)\]]{1,})\2""",
)

# 7. Credit Card numbers — 13-19 chữ số, có thể phân cách bởi dấu gạch/khoảng trắng
_RE_CREDIT_CARD = re.compile(
    r"\b(?:\d[ -]*?){13,19}\b"
)

# Danh sách patterns theo thứ tự ưu tiên (specific → generic)
_SCRUB_PATTERNS: list[tuple[re.Pattern, str | None]] = [
    (_RE_BEARER_TOKEN, SCRUB_REPLACEMENT),
    (_RE_BASIC_AUTH, SCRUB_REPLACEMENT),
    (_RE_AWS_ACCESS_KEY, SCRUB_REPLACEMENT),
    (_RE_AWS_SECRET_KEY, SCRUB_REPLACEMENT),
    # Password field: giữ key, chỉ scrub value
    (_RE_PASSWORD_FIELD, None),  # xử lý riêng
    (_RE_EMAIL, SCRUB_REPLACEMENT),
    (_RE_CREDIT_CARD, SCRUB_REPLACEMENT),
]


# ---------------------------------------------------------------------------
# CORE SCRUBBING FUNCTION
# ---------------------------------------------------------------------------

def scrub(text: str) -> str:
    """
    Tìm và thay thế tất cả PII / secrets / credentials trong text bằng [SCRUBBED].

    Hàm này idempotent — gọi nhiều lần trên cùng text không làm hỏng dữ liệu.
    Đã scrubbed rồi ([SCRUBBED]) sẽ không bị thay đổi thêm.

    Args:
        text: Chuỗi cần scrub (log message, JSON payload, ...).

    Returns:
        Chuỗi đã được scrub.

    Examples:
        >>> scrub("key=AKIAIOSFODNN7EXAMPLE")
        'key=[SCRUBBED]'
        >>> scrub('{"password": "s3cret!"}')
        '{"password": "[SCRUBBED]"}'
    """
    if not text or SCRUB_REPLACEMENT == text:
        return text

    for pattern, replacement in _SCRUB_PATTERNS:
        if pattern is _RE_PASSWORD_FIELD:
            # Giữ tên key, chỉ scrub giá trị
            text = pattern.sub(_password_replacer, text)
        elif replacement is not None:
            text = pattern.sub(replacement, text)

    return text


def _password_replacer(match: re.Match) -> str:
    """Callback cho _RE_PASSWORD_FIELD: giữ key + dấu phân cách, scrub value."""
    key_part = match.group(1)   # e.g. "password": hoặc PASSWORD=
    quote = match.group(2)      # quote character (nếu có)
    return f"{key_part}{quote}{SCRUB_REPLACEMENT}{quote}"


# ---------------------------------------------------------------------------
# DICT / PAYLOAD SCRUBBING
# ---------------------------------------------------------------------------

def scrub_dict(data: dict[str, Any]) -> dict[str, Any]:
    """
    Deep-scrub một dictionary (JSON payload) — scrub tất cả string values.

    Hữu ích khi cần scrub telemetry payload trước khi gửi SQS / Firehose.
    Không mutate dict gốc — trả về bản copy mới.

    Args:
        data: Dictionary cần scrub.

    Returns:
        Dictionary mới với tất cả string values đã scrub.
    """
    return _scrub_recursive(data)


def _scrub_recursive(obj: Any, key_name: str = "") -> Any:
    """Đệ quy scrub tất cả string values trong cấu trúc lồng nhau."""
    if isinstance(obj, str):
        key_norm = key_name.lower().replace("-", "_") if key_name else ""
        if key_norm and any(sk in key_norm for sk in _SENSITIVE_KEYS):
            return SCRUB_REPLACEMENT
        return scrub(obj)
    if isinstance(obj, dict):
        return {k: _scrub_recursive(v, key_name=k) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        scrubbed = [_scrub_recursive(item, key_name) for item in obj]
        return type(obj)(scrubbed)
    return obj


# ---------------------------------------------------------------------------
# SENSITIVE KEY NAMES — dùng cho scrub_dict nâng cao
# ---------------------------------------------------------------------------

_SENSITIVE_KEYS = frozenset({
    "password", "passwd", "pwd", "secret", "secret_key",
    "api_key", "apikey", "token", "auth_token", "access_token",
    "refresh_token", "authorization", "credential", "credentials",
    "aws_secret_access_key", "aws_access_key_id",
    "private_key", "ssh_key",
})


def scrub_dict_by_keys(data: dict[str, Any]) -> dict[str, Any]:
    """
    Scrub dictionary theo tên key nhạy cảm — bất kể giá trị có match regex hay không.

    Dùng khi cần đảm bảo 100% không lọt secret qua audit trail,
    kể cả khi secret format không match bất kỳ regex nào.

    Args:
        data: Dictionary cần scrub.

    Returns:
        Dictionary mới với key nhạy cảm đã scrub.
    """
    return _scrub_by_keys_recursive(data)


def _scrub_by_keys_recursive(obj: Any, parent_key: str = "") -> Any:
    """Đệ quy scrub value theo tên key."""
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            k_norm = k.lower().replace("-", "_") if isinstance(k, str) else ""
            if k_norm and any(sk in k_norm for sk in _SENSITIVE_KEYS):
                result[k] = SCRUB_REPLACEMENT
            else:
                result[k] = _scrub_by_keys_recursive(v, parent_key=k)
        return result
    if isinstance(obj, (list, tuple)):
        scrubbed = [_scrub_by_keys_recursive(item, parent_key) for item in obj]
        return type(obj)(scrubbed)
    if isinstance(obj, str):
        key_norm = parent_key.lower().replace("-", "_") if parent_key else ""
        if key_norm and any(sk in key_norm for sk in _SENSITIVE_KEYS):
            return SCRUB_REPLACEMENT
        return scrub(obj)
    return obj

