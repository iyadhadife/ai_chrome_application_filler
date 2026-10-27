#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 7 : Gestion des limites API (Rate Limits)..."

cat << 'EOF' > "$PROJECT_DIR/backend/app/llm/groq_client.py"
import json
import httpx
import asyncio
from typing import Dict, Any, Optional
from app.config import settings

class GroqClient:
    BASE_URL = "https://api.groq.com/openai/v1/chat/completions"

    def __init__(self, api_key: Optional[str] = None, model: Optional[str] = None):
        self.api_key = api_key or settings.GROQ_API_KEY
        self.model = model or settings.GROQ_MODEL

    async def generate_json(self, system_prompt: str, user_payload: Dict[str, Any], retries: int = 2) -> Dict[str, Any]:
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
            "max_tokens": 1500  # Réduit pour ne pas saturer la limite de 8000 TPM de Groq
        }
        
        for attempt in range(retries):
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(self.BASE_URL, headers=headers, json=payload)
                
                # Gestion automatique de la limite de requêtes (HTTP 429)
                if response.status_code == 429:
                    error_data = response.json()
                    err_msg = error_data.get("error", {}).get("message", "")
                    print(f"\n[RATE LIMIT] Limite Groq atteinte. Pause de 20 secondes avant de réessayer... ({err_msg})\n")
                    await asyncio.sleep(20)
                    continue # On retente la boucle
                
                if response.status_code != 200:
                    raise RuntimeError(f"Erreur API Groq: {response.text}")
                
                content = response.json()["choices"][0]["message"]["content"].strip()
                
                if "```json" in content:
                    content = content.split("```json")[1].split("```")[0].strip()
                elif "```" in content:
                    content = content.split("```")[1].strip()
                
                try:
                    return json.loads(content)
                except Exception:
                    print(f"\n[ERREUR JSON] Impossible de parser la réponse: {content}\n")
                    return {}
        
        raise RuntimeError("Échec après plusieurs tentatives suite aux limites de l'API Groq.")
EOF
echo "✅ Backend protégé contre les limites de tokens !"