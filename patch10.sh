#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 10 : Auto-Réparation JSON et Optimisation des Tokens..."

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
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/form_analyzer/skill.md"
# Agent: Form Analyzer Agent

## Rôle
Tu es un agent expert en analyse structurelle de formulaires DOM web.

## Sorties
Un objet JSON contenant la clé `analyzed_fields` avec pour chaque champ :
- `field_id`: Identifiant exact d'origine.
- `clean_label`: Intitulé humain clair.
- `context_summary`: Résumé ultra-court de la demande.
- `is_sensitive`: Booléen.

## Règles STRICTES à suivre (POUR SAUVER DES TOKENS)
1. `context_summary` DOIT être extrêmement court (maximum 3 à 5 mots).
2. `is_sensitive` DOIT être `true` UNIQUEMENT pour les mots de passe, cartes bancaires ou sécurité sociale.
3. IMPORTANT : Les Prénoms (Given Name), Noms, Pays (Country), Emails et Téléphones NE SONT PAS sensibles (`is_sensitive`: false).
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
        
        # OPTIMISATION : On retire les 'options' énormes pour l'analyseur
        simplified_fields = []
        for f in raw_fields:
            simplified_fields.append({
                "field_id": f.field_id,
                "label": f.label,
                "placeholder": f.placeholder,
                "name": f.name,
                "type": f.input_type
            })
        
        analyzer_prompt = self.load_skill_prompt("form_analyzer")
        analyzer_output = await llm.generate_json(analyzer_prompt, {"url": url, "page_title": page_title, "fields": simplified_fields})
        
        enriched_analyzed = [{"field_id": str(f.get("field_id") or "")} for f in analyzer_output.get("analyzed_fields", []) if isinstance(f, dict)]
        
        classifier_prompt = self.load_skill_prompt("field_classifier")
        classifier_output = await llm.generate_json(classifier_prompt, {"analyzed_fields": enriched_analyzed, "available_profile_keys": available_profile_keys})
        
        results = []
        for c in classifier_output.get("classified_fields", []):
            if not isinstance(c, dict): continue
            results.append(ClassifiedField(
                field_id=str(c.get("field_id") or ""), label_detected=str(c.get("label_detected") or ""),
                semantic_key=str(c.get("semantic_key") or "unknown"), category=str(c.get("category") or "general"),
                expected_format=str(c.get("expected_format") or "text"), is_sensitive=bool(c.get("is_sensitive"))
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
                field_id=str(item.get("field_id") or ""), 
                semantic_key=str(item.get("semantic_key") or "unknown"), 
                label_detected=str(item.get("label_detected") or ""),
                status=str(item.get("status") or "missing_information"), 
                raw_profile_value=item.get("raw_profile_value")
            ))
        return resolved_results

    async def generate_missing_info_questions(self, missing_fields: List[ResolvedFieldStatus]) -> List[MissingInfoQuestion]:
        targets = [f for f in missing_fields if f.status == "missing_information"]
        if not targets: return []
        llm = self._get_llm_client()
        missing_prompt = self.load_skill_prompt("missing_info")
        output = await llm.generate_json(missing_prompt, {"missing_fields": [t.model_dump() for t in targets]})
        
        return [MissingInfoQuestion(
            field_id=str(q.get("field_id") or ""), semantic_key=str(q.get("semantic_key") or ""),
            question_fr=str(q.get("question_fr") or ""), suggested_placeholder=str(q.get("suggested_placeholder") or "")
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
                field_id=str(item.get("field_id") or ""), semantic_key=str(item.get("semantic_key") or ""),
                final_value=str(item.get("final_value") or ""), confidence=float(conf)
            ))
        return direct_filled
EOF
echo "✅ Système auto-réparant déployé !"