import json
import httpx
from typing import Dict, Any, Optional
from app.config import settings

class GroqClient:
    BASE_URL = "https://api.groq.com/openai/v1/chat/completions"

    def __init__(self, api_key: Optional[str] = None, model: Optional[str] = None):
        self.api_key = api_key or settings.GROQ_API_KEY
        self.model = model or settings.GROQ_MODEL

    async def generate_json(self, system_prompt: str, user_payload: Dict[str, Any]) -> Dict[str, Any]:
        if not self.api_key:
            raise ValueError("Clé API Groq manquante.")
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": json.dumps(user_payload, ensure_ascii=False)}
            ],
            "temperature": 0.1,
            "response_format": {"type": "json_object"}
        }
        async with httpx.AsyncClient(timeout=45.0) as client:
            response = await client.post(self.BASE_URL, headers=headers, json=payload)
            if response.status_code != 200:
                raise RuntimeError(f"Erreur API Groq: {response.text}")
            return json.loads(response.json()["choices"][0]["message"]["content"])
