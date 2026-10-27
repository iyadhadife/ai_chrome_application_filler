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
            "max_tokens": 1800
        }
        
        for attempt in range(retries):
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(self.BASE_URL, headers=headers, json=payload)
                
                if response.status_code == 429:
                    error_data = response.json()
                    err_msg = error_data.get("error", {}).get("message", "")
                    print(f"\n[RATE LIMIT] Pause de 20s... ({err_msg})\n")
                    await asyncio.sleep(20)
                    continue
                
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
                    # AUTO-RÉPARATION : Si l'IA est coupée, on ferme de force le JSON pour sauver le travail
                    last_obj_end = content.rfind("}")
                    if last_obj_end != -1:
                        try:
                            return json.loads(content[:last_obj_end+1] + "\n  ]\n}")
                        except:
                            try:
                                return json.loads(content[:last_obj_end+1] + "\n}")
                            except:
                                pass
                    print(f"\n[ERREUR JSON] Impossible de réparer la réponse tronquée.\n")
                    return {}
        
        raise RuntimeError("Échec après plusieurs tentatives.")
