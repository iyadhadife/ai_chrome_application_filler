#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 4 : Blindage contre les valeurs 'null' de l'IA..."

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
        
        enriched_analyzed = [{"field_id": str(f.get("field_id") or "")} for f in analyzer_output.get("analyzed_fields", []) if isinstance(f, dict)]
        
        classifier_prompt = self.load_skill_prompt("field_classifier")
        classifier_output = await llm.generate_json(classifier_prompt, {"analyzed_fields": enriched_analyzed, "available_profile_keys": available_profile_keys})
        
        results = []
        for c in classifier_output.get("classified_fields", []):
            if not isinstance(c, dict): continue
            
            # Protection contre les "null" renvoyés par l'IA
            field_id = str(c.get("field_id") or "")
            label_detected = str(c.get("label_detected") or "")
            semantic_key = str(c.get("semantic_key") or "unknown")
            category = str(c.get("category") or "general")
            expected_format = str(c.get("expected_format") or "text")
            is_sensitive = bool(c.get("is_sensitive"))
            
            results.append(ClassifiedField(
                field_id=field_id, label_detected=label_detected,
                semantic_key=semantic_key, category=category,
                expected_format=expected_format, is_sensitive=is_sensitive
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
                raw_profile_value=item.get("raw_profile_value") # raw_profile_value autorise les null (Optional)
            ))
        return resolved_results

    async def generate_missing_info_questions(self, missing_fields: List[ResolvedFieldStatus]) -> List[MissingInfoQuestion]:
        targets = [f for f in missing_fields if f.status == "missing_information"]
        if not targets: return []
        llm = self._get_llm_client()
        missing_prompt = self.load_skill_prompt("missing_info")
        output = await llm.generate_json(missing_prompt, {"missing_fields": [t.model_dump() for t in targets]})
        
        return [MissingInfoQuestion(
            field_id=str(q.get("field_id") or ""), 
            semantic_key=str(q.get("semantic_key") or ""),
            question_fr=str(q.get("question_fr") or ""), 
            suggested_placeholder=str(q.get("suggested_placeholder") or "")
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
                field_id=str(item.get("field_id") or ""), 
                semantic_key=str(item.get("semantic_key") or ""),
                final_value=str(item.get("final_value") or ""), 
                confidence=float(conf)
            ))
        return direct_filled
EOF
echo "✅ Ordonnanceur Pydantic sécurisé !"