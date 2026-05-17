from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
from pathlib import Path
from typing import Any
import urllib.error
import urllib.request


OPENROUTER_CHAT_COMPLETIONS_URL = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
DEFAULT_SITE_URL = "http://localhost:3000"
DEFAULT_APP_NAME = "Municipal Program Agent"


class OpenRouterError(RuntimeError):
    """Raised when OpenRouter returns an unusable response."""


@dataclass(frozen=True)
class OpenRouterClient:
    api_key: str = field(repr=False)
    model: str = DEFAULT_MODEL
    site_url: str = DEFAULT_SITE_URL
    app_name: str = DEFAULT_APP_NAME
    temperature: float = 0.1
    max_tokens: int | None = None
    timeout_seconds: int = 60
    endpoint: str = OPENROUTER_CHAT_COMPLETIONS_URL

    def __post_init__(self) -> None:
        api_key = self.api_key.strip()
        if not api_key:
            raise ValueError("OPENROUTER_API_KEY is required for OpenRouterClient")
        object.__setattr__(self, "api_key", api_key)

    @classmethod
    def from_env(cls, model: str | None = None) -> "OpenRouterClient":
        return cls(
            api_key=os.environ.get("OPENROUTER_API_KEY", ""),
            model=model or os.environ.get("OPENROUTER_MODEL_PRIMARY", DEFAULT_MODEL),
            site_url=os.environ.get("OPENROUTER_SITE_URL", DEFAULT_SITE_URL),
            app_name=os.environ.get("OPENROUTER_APP_NAME", DEFAULT_APP_NAME),
            temperature=_env_float("LLM_TEMPERATURE", 0.1),
            max_tokens=_env_optional_int("LLM_MAX_OUTPUT_TOKENS"),
        )

    def chat(self, system_prompt: str, user_prompt: str) -> str:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": self.temperature,
        }
        if self.max_tokens is not None:
            payload["max_tokens"] = self.max_tokens

        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "HTTP-Referer": self.site_url,
                "X-OpenRouter-Title": self.app_name,
                "Content-Type": "application/json",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                raw = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise OpenRouterError(f"OpenRouter HTTP {exc.code}: {_redact_secret(detail, self.api_key)}") from exc
        except urllib.error.URLError as exc:
            raise OpenRouterError(f"OpenRouter request failed: {exc.reason}") from exc

        return _extract_message_content(json.loads(raw))


def explain_mapping_report(
    mapping_report: dict[str, Any] | str | Path,
    client: OpenRouterClient | None = None,
    model: str | None = None,
) -> dict[str, str]:
    report = _load_mapping_report(mapping_report)
    llm_client = client or OpenRouterClient.from_env(model=model)
    prompt_payload = {
        "docx": {"passport_totals_by_year": report.get("docx", {}).get("passport_totals_by_year", {})},
        "excel": {
            "program_totals": report.get("excel", {}).get("program_totals", {}),
            "residual_group_count": report.get("excel", {}).get("residual_group_count"),
            "known_duplicate_groups": report.get("excel", {}).get("known_duplicate_groups", []),
        },
        "procedure_pdf": {"rules": report.get("procedure_pdf", {}).get("rules", [])},
        "reconciliation": report.get("reconciliation", []),
    }
    content = llm_client.chat(
        system_prompt=(
            "Ты агент муниципальной программы. Объясняй расхождения и риски по готовым "
            "данным parser_worker. Не пересчитывай деньги, не меняй контрольные суммы и "
            "не предлагай правки без явного подтверждения пользователя."
        ),
        user_prompt=json.dumps(prompt_payload, ensure_ascii=False, indent=2),
    )
    return {
        "model": llm_client.model,
        "purpose": "reconciliation_explanation",
        "content": content,
    }


def _extract_message_content(payload: dict[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise OpenRouterError("OpenRouter response has no choices")

    first = choices[0]
    if isinstance(first, dict):
        message = first.get("message")
        if isinstance(message, dict) and isinstance(message.get("content"), str):
            return message["content"]
        if isinstance(first.get("text"), str):
            return first["text"]

    raise OpenRouterError("OpenRouter response has no message content")


def _load_mapping_report(mapping_report: dict[str, Any] | str | Path) -> dict[str, Any]:
    if isinstance(mapping_report, dict):
        return mapping_report
    path = Path(mapping_report)
    return json.loads(path.read_text(encoding="utf-8"))


def _env_float(name: str, default: float) -> float:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    return float(value)


def _env_optional_int(name: str) -> int | None:
    value = os.environ.get(name, "").strip()
    if not value:
        return None
    return int(value)


def _redact_secret(text: str, secret: str) -> str:
    if not secret:
        return text
    return text.replace(secret, "[REDACTED]")
