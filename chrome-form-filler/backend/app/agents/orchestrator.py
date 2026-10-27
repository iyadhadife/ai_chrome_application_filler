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
        
        simplified_fields = [{"field_id": f.field_id, "label": f.label, "name": f.name, "type": f.input_type} for f in raw_fields]
        
        analyzer_prompt = self.load_skill_prompt("form_analyzer")
        analyzer_output = await llm.generate_json(analyzer_prompt, {"url": url, "page_title": page_title, "fields": simplified_fields})
        
        enriched_analyzed = [{"field_id": str(f.get("field_id") or "")} for f in analyzer_output.get("analyzed_fields", []) if isinstance(f, dict)]
        
        classifier_prompt = self.load_skill_prompt("field_classifier")
        classifier_output = await llm.generate_json(classifier_prompt, {"analyzed_fields": enriched_analyzed, "available_profile_keys": available_profile_keys})
        
        results = []
        for c in classifier_output.get("classified_fields", []):
            if not isinstance(c, dict): continue
            res = ClassifiedField(
                field_id=str(c.get("field_id") or ""), label_detected=str(c.get("label_detected") or ""),
                semantic_key=str(c.get("semantic_key") or "unknown").lower(), category=str(c.get("category") or "general"),
                expected_format=str(c.get("expected_format") or "text"), is_sensitive=bool(c.get("is_sensitive"))
            )
            
            # --- SUPER HACK : Auto-correction des hallucinations de l'IA ---
            lbl = (res.label_detected + " " + res.field_id).lower()
            if "first" in lbl or "prénom" in lbl or "prenom" in lbl or "given" in lbl: res.semantic_key = "first_name"
            elif "last" in lbl or "nom" in lbl or "family" in lbl or "surname" in lbl: res.semantic_key = "last_name"
            elif "mail" in lbl: res.semantic_key = "email"
            elif "phone" in lbl or "téléphone" in lbl or "telephone" in lbl: res.semantic_key = "phone"
            elif "city" in lbl or "ville" in lbl: res.semantic_key = "city"
            elif "country" in lbl or "pays" in lbl: res.semantic_key = "country"
            # ---------------------------------------------------------------
            
            results.append(res)
        return results

    async def resolve_profile_fields(self, classified_fields: List[ClassifiedField], user_profile: Dict[str, str]) -> List[ResolvedFieldStatus]:
        resolved_results = []
        fields_needing_llm = []

        for field in classified_fields:
            # Bypass direct de l'IA si la clé correspond à la base de données
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
        slim_fields = [{"field_id": f.field_id, "semantic_key": f.semantic_key, "label_detected": f.label_detected} for f in fields_needing_llm]
        resolver_output = await llm.generate_json(resolver_prompt, {"classified_fields": slim_fields, "profile_keys_and_values": user_profile})
        
        for item in resolver_output.get("resolved_fields", []):
            if not isinstance(item, dict): continue
            resolved_results.append(ResolvedFieldStatus(
                field_id=str(item.get("field_id") or ""), semantic_key=str(item.get("semantic_key") or "unknown"), 
                label_detected=str(item.get("label_detected") or ""), status=str(item.get("status") or "missing_information"), 
                raw_profile_value=item.get("raw_profile_value")
            ))
        return resolved_results

    async def generate_missing_info_questions(self, missing_fields: List[ResolvedFieldStatus]) -> List[MissingInfoQuestion]:
        targets = [f for f in missing_fields if f.status == "missing_information"]
        if not targets: return []
        llm = self._get_llm_client()
        missing_prompt = self.load_skill_prompt("missing_info")
        output = await llm.generate_json(missing_prompt, {"missing_fields": [{"field_id": t.field_id, "semantic_key": t.semantic_key} for t in targets]})
        
        return [MissingInfoQuestion(
            field_id=str(q.get("field_id") or ""), semantic_key=str(q.get("semantic_key") or ""),
            question_fr=str(q.get("question_fr") or ""), suggested_placeholder=str(q.get("suggested_placeholder") or "")
        ) for q in output.get("questions", []) if isinstance(q, dict)]

    async def generate_final_field_values(self, resolved_fields: List[ResolvedFieldStatus], page_context: str = "") -> List[FilledFieldItem]:
        ready_fields = [f for f in resolved_fields if f.status == "resolved" and f.raw_profile_value]
        if not ready_fields: return []
        
        direct_filled = []
        llm_targets = []
        
        # BYPASS LLM FINAL : On ne dérange l'IA que pour les menus déroulants et les textes longs (motivation)
        for rf in ready_fields:
            if rf.options or rf.expected_format in ["paragraph", "select_option"] or len(rf.raw_profile_value) > 100:
                llm_targets.append(rf)
            else:
                direct_filled.append(FilledFieldItem(
                    field_id=rf.field_id, semantic_key=rf.semantic_key,
                    final_value=rf.raw_profile_value.strip(), confidence=1.0
                ))
        
        if not llm_targets: return direct_filled

        llm = self._get_llm_client()
        filler_prompt = self.load_skill_prompt("form_filler")
        output = await llm.generate_json(filler_prompt, {"page_context": page_context, "fields_to_fill": [f.model_dump() for f in llm_targets]})
        
        for item in output.get("filled_fields", []):
            if not isinstance(item, dict): continue
            conf = item.get("confidence", 1.0)
            direct_filled.append(FilledFieldItem(
                field_id=str(item.get("field_id") or ""), semantic_key=str(item.get("semantic_key") or ""),
                final_value=str(item.get("final_value") or ""), confidence=float(conf if conf is not None else 1.0)
            ))
            
        return direct_filled
