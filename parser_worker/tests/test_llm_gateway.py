import json

import pytest

from municipal_agent.llm_gateway import OpenRouterClient, explain_mapping_report


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return json.dumps({"choices": [{"message": {"content": "Объяснение расхождений"}}]}).encode("utf-8")


def test_openrouter_client_sends_chat_completion_without_leaking_key(monkeypatch):
    captured = {}

    def fake_urlopen(request, timeout):
        captured["url"] = request.full_url
        captured["headers"] = dict(request.header_items())
        captured["body"] = json.loads(request.data.decode("utf-8"))
        captured["timeout"] = timeout
        return FakeResponse()

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

    client = OpenRouterClient(
        api_key="sk-or-v1-secret",
        model="deepseek/deepseek-v4-pro",
        site_url="http://localhost:3000",
        app_name="Municipal Program Agent",
    )
    content = client.chat(
        system_prompt="Ты объясняешь расхождения, но не считаешь деньги.",
        user_prompt='{"status":"PROGRAM_TOTAL_DIFF"}',
    )

    assert content == "Объяснение расхождений"
    assert captured["url"] == "https://openrouter.ai/api/v1/chat/completions"
    headers = {key.lower(): value for key, value in captured["headers"].items()}
    assert headers["authorization"] == "Bearer sk-or-v1-secret"
    assert headers["http-referer"] == "http://localhost:3000"
    assert headers["x-openrouter-title"] == "Municipal Program Agent"
    assert captured["body"]["model"] == "deepseek/deepseek-v4-pro"
    assert captured["body"]["temperature"] == 0.1


def test_openrouter_client_requires_api_key():
    with pytest.raises(ValueError, match="OPENROUTER_API_KEY"):
        OpenRouterClient(api_key="", model="deepseek/deepseek-v4-pro")


def test_openrouter_client_can_be_built_from_env(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-v1-env")
    monkeypatch.setenv("OPENROUTER_MODEL_PRIMARY", "deepseek/deepseek-v4-pro")
    monkeypatch.setenv("OPENROUTER_SITE_URL", "http://localhost:3000")
    monkeypatch.setenv("OPENROUTER_APP_NAME", "Municipal Program Agent")
    monkeypatch.setenv("LLM_TEMPERATURE", "0.2")
    monkeypatch.setenv("LLM_MAX_OUTPUT_TOKENS", "512")

    client = OpenRouterClient.from_env()

    assert client.model == "deepseek/deepseek-v4-pro"
    assert client.site_url == "http://localhost:3000"
    assert client.temperature == 0.2
    assert client.max_tokens == 512
    assert "sk-or-v1-env" not in repr(client)


def test_openrouter_client_from_env_accepts_model_override(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-v1-env")
    monkeypatch.setenv("OPENROUTER_MODEL_PRIMARY", "deepseek/deepseek-v4-flash")

    client = OpenRouterClient.from_env(model="deepseek/deepseek-v4-pro")

    assert client.model == "deepseek/deepseek-v4-pro"


def test_explain_mapping_report_sends_only_report_subset_to_llm():
    class FakeClient:
        model = "deepseek/deepseek-v4-pro"

        def __init__(self):
            self.system_prompt = None
            self.user_prompt = None

        def chat(self, system_prompt, user_prompt):
            self.system_prompt = system_prompt
            self.user_prompt = user_prompt
            return "Расхождения требуют проверки источников финансирования."

    report = {
        "docx": {"passport_totals_by_year": {"2026": "2296101960.00"}},
        "excel": {"program_totals": {"2026": "2253220255.91"}, "residual_group_count": 18},
        "procedure_pdf": {"rules": ["Изменения не требуют направления в КСП."]},
        "reconciliation": [{"status": "PROGRAM_TOTAL_DIFF", "year": 2026, "delta_rub": "-42881704.09"}],
    }

    fake_client = FakeClient()
    result = explain_mapping_report(report, client=fake_client)
    prompt_payload = json.loads(fake_client.user_prompt)

    assert result == {
        "model": "deepseek/deepseek-v4-pro",
        "purpose": "reconciliation_explanation",
        "content": "Расхождения требуют проверки источников финансирования.",
    }
    assert "не пересчитывай деньги" in fake_client.system_prompt.lower()
    assert prompt_payload["reconciliation"][0]["status"] == "PROGRAM_TOTAL_DIFF"
    assert prompt_payload["excel"]["residual_group_count"] == 18
