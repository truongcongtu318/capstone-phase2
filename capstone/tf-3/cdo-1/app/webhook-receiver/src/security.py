# 🔒 SOC2 Compliance - Log Scrubbing Middleware
# TODO: Viết hàm apply regex để tìm và thay thế (PII, AWS secrets, bearer tokens) bằng "[SCRUBBED]".
# Hàm này sẽ được nhúng vào logger chung hoặc làm FastAPI Middleware để filter dữ liệu telemetry.
import re

PATTERNS = [

    (re.compile(r"AKIA[0-9A-Z]{16}"), "[SCRUBBED]"),                        # AWS Access Key
    (re.compile(r"(?i)(Bearer\s+)[A-Za-z0-9\-._~+/]+=*"), r"\1[SCRUBBED]"), # Bearer token
    (re.compile(r"[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+"), "[SCRUBBED]"), # Email

]

def scrub(text: str) -> str:
    for pattern, replacement in PATTERNS:
        text = pattern.sub(replacement, text)
    return text
