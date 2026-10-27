#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 3 : Parsing JSON robuste..."

cat << 'EOF' > "$PROJECT_DIR/backend/app/llm/groq_client.py"
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
            "temperature": 0.1
            # Nous retirons 'response_format' car certains modèles non-standards le rejettent
        }
        async with httpx.AsyncClient(timeout=45.0) as client:
            response = await client.post(self.BASE_URL, headers=headers, json=payload)
            if response.status_code != 200:
                raise RuntimeError(f"Erreur API Groq: {response.text}")
            
            content = response.json()["choices"][0]["message"]["content"].strip()
            
            # Nettoyage robuste des balises Markdown (```json ... ```)
            if "```json" in content:
                content = content.split("```json")[1].split("```")[0].strip()
            elif "```" in content:
                content = content.split("```")[1].strip()
            
            try:
                return json.loads(content)
            except Exception:
                print(f"\n[ERREUR JSON] Impossible de parser la réponse: {content}\n")
                return {} # Retourne un objet vide au lieu de faire crasher l'API
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/orchestrator.py"
from typing import Dict, Any, List, Optional
from app.config import settings
from app.llm.groq_client import GroqClient
from app.llm.openai_client import OpenAIClient
from app.models.schemas import RawDOMField, ClassifiedField, ResolvedFieldStatus, MissingInfoQuestion, FilledFieldItem

class AgentOrchestrator:
    def __init__(self, provider: Optional[str] = None, model: Optional[str] = None):
        self.provider = (provider or settings.LLM_PROVIDER).lower()
        self.model = model

    def _get_llm_client(self):
        if self.provider == "openai": return OpenAIClient(model=self.model or settings.OPENAI_MODEL)
        return GroqClient(model=self.model or settings.GROQ_MODEL)

    def load_skill_prompt(self, agent_folder: str) -> str:
        skill_path = settings.AGENTS_DIR / agent_folder / "skill.md"
        return skill_path.read_text(encoding="utf-8")

    async def analyze_and_classify(self, url: str, page_title: str, raw_fields: List[RawDOMField], available_profile_keys: List[str]) -> List[ClassifiedField]:
        if not raw_fields: return []
        llm = self._get_llm_client()
        
        analyzer_prompt = self.load_skill_prompt("form_analyzer")
        analyzer_output = await llm.generate_json(analyzer_prompt, {"url": url, "page_title": page_title, "fields": [f.model_dump() for f in raw_fields]})
        
        enriched_analyzed = [{"field_id": f.get("field_id")} for f in analyzer_output.get("analyzed_fields", []) if isinstance(f, dict)]
        
        classifier_prompt = self.load_skill_prompt("field_classifier")
        classifier_output = await llm.generate_json(classifier_prompt, {"analyzed_fields": enriched_analyzed, "available_profile_keys": available_profile_keys})
        
        results = []
        for c in classifier_output.get("classified_fields", []):
            if not isinstance(c, dict): continue
            results.append(ClassifiedField(
                field_id=c.get("field_id", ""), label_detected=c.get("label_detected", ""),
                semantic_key=c.get("semantic_key", "unknown"), category=c.get("category", "general"),
                expected_format=c.get("expected_format", "text"), is_sensitive=bool(c.get("is_sensitive", False))
            ))
        return results

    async def resolve_profile_fields(self, classified_fields: List[ClassifiedField], user_profile: Dict[str, str]) -> List[ResolvedFieldStatus]:
        resolved_results = []
        fields_needing_llm = []

        for field in classified_fields:
            if field.semantic_key in user_profile and user_profile[field.semantic_key].strip():
                resolved_results.append(ResolvedFieldStatus(
                    field_id=field.field_id, semantic_key=field.semantic_key, label_detected=field.label_detected,
                    status="resolved", raw_profile_value=user_profile[field.semantic_key]
                ))
            else:
                fields_needing_llm.append(field)

        if not fields_needing_llm: return resolved_results

        llm = self._get_llm_client()
        resolver_prompt = self.load_skill_prompt("profile_resolver")
        resolver_output = await llm.generate_json(resolver_prompt, {"classified_fields": [f.model_dump() for f in fields_needing_llm], "profile_keys_and_values": user_profile})
        
        for item in resolver_output.get("resolved_fields", []):
            if not isinstance(item, dict): continue
            resolved_results.append(ResolvedFieldStatus(
                field_id=item.get("field_id"), semantic_key=item.get("semantic_key"), label_detected=item.get("label_detected", ""),
                status=item.get("status", "missing_information"), raw_profile_value=item.get("raw_profile_value")
            ))
        return resolved_results

    async def generate_missing_info_questions(self, missing_fields: List[ResolvedFieldStatus]) -> List[MissingInfoQuestion]:
        targets = [f for f in missing_fields if f.status == "missing_information"]
        if not targets: return []
        llm = self._get_llm_client()
        missing_prompt = self.load_skill_prompt("missing_info")
        output = await llm.generate_json(missing_prompt, {"missing_fields": [t.model_dump() for t in targets]})
        return [MissingInfoQuestion(
            field_id=q.get("field_id", ""), semantic_key=q.get("semantic_key", ""),
            question_fr=q.get("question_fr", ""), suggested_placeholder=q.get("suggested_placeholder", "")
        ) for q in output.get("questions", []) if isinstance(q, dict)]

    async def generate_final_field_values(self, resolved_fields: List[ResolvedFieldStatus], page_context: str = "") -> List[FilledFieldItem]:
        ready_fields = [f for f in resolved_fields if f.status == "resolved" and f.raw_profile_value]
        if not ready_fields: return []
        direct_filled = []
        llm = self._get_llm_client()
        filler_prompt = self.load_skill_prompt("form_filler")
        output = await llm.generate_json(filler_prompt, {"page_context": page_context, "fields_to_fill": [f.model_dump() for f in ready_fields]})
        
        for item in output.get("filled_fields", []):
            if not isinstance(item, dict): continue
            conf = item.get("confidence")
            if conf is None: conf = 1.0
            direct_filled.append(FilledFieldItem(
                field_id=item.get("field_id", ""), semantic_key=item.get("semantic_key", ""),
                final_value=str(item.get("final_value", "")), confidence=float(conf)
            ))
        return direct_filled
EOF
echo "✅ Backend sécurisé !"