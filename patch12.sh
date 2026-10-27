#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 12 : Architecture Hybride Heuristique + IA..."

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/orchestrator.py"
from typing import Dict, Any, List, Optional
from app.config import settings
from app.llm.groq_client import GroqClient
from app.llm.openai_client import OpenAIClient
from app.models.schemas import RawDOMField, ClassifiedField, ResolvedFieldStatus, MissingInfoQuestion, FilledFieldItem
import re

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
        results = []
        for f in raw_fields:
            # Agrégation des métadonnées pour la détection
            lbl = f"{f.label} {f.name} {f.placeholder} {f.dom_id}".lower()
            s_key = "unknown"
            
            # --- HEURISTIQUES LOCALES ULTRA-RAPIDES (Bypass IA) ---
            if "first" in lbl or "prénom" in lbl or "prenom" in lbl or "given" in lbl: s_key = "first_name"
            elif "last" in lbl or "nom" in lbl or "family" in lbl or "surname" in lbl: s_key = "last_name"
            elif "mail" in lbl: s_key = "email"
            elif "phone" in lbl or "téléphone" in lbl or "telephone" in lbl or "mobile" in lbl: s_key = "phone"
            elif "city" in lbl or "ville" in lbl: s_key = "city"
            elif "country" in lbl or "pays" in lbl or "nation" in lbl: s_key = "country"
            elif "zip" in lbl or "postal" in lbl: s_key = "postal_code"
            elif "address" in lbl or "adresse" in lbl or "street" in lbl or "rue" in lbl: s_key = "address_street"
            elif "linkedin" in lbl: s_key = "linkedin_url"
            elif "github" in lbl: s_key = "github_url"
            elif "portfolio" in lbl or "website" in lbl or "site" in lbl: s_key = "portfolio_url"
            elif "title" in lbl or "titre" in lbl or "poste" in lbl: s_key = "job_title"
            elif "school" in lbl or "école" in lbl or "ecole" in lbl or "university" in lbl or "université" in lbl: s_key = "education_school"
            elif "degree" in lbl or "diplôme" in lbl or "diplome" in lbl: s_key = "education_degree"
            elif "experience" in lbl: s_key = "experience_summary"
            elif "skill" in lbl or "compétence" in lbl or "competence" in lbl: s_key = "technical_skills"
            elif "language" in lbl or "langue" in lbl: s_key = "languages"
            elif "salary" in lbl or "salaire" in lbl or "expectation" in lbl or "prétention" in lbl: s_key = "salary_expectations"
            elif "cover" in lbl or "motivation" in lbl: s_key = "cover_letter"
            elif "bio" in lbl or "summary" in lbl or "résumé" in lbl: s_key = "short_bio"
            else:
                # Fallback propre sur le nom du champ
                clean_name = re.sub(r'[^a-z0-9_]', '', (f.name or "").replace("-", "_").strip())
                if clean_name and len(clean_name) > 2: s_key = clean_name
            
            is_sens = "password" in f.input_type.lower() or "password" in lbl or "mot de passe" in lbl or "ssn" in lbl or "social" in lbl
            
            results.append(ClassifiedField(
                field_id=f.field_id,
                label_detected=f.label or f.placeholder or f.name or f.field_id,
                semantic_key=s_key,
                category="general",
                expected_format="select_option" if f.options else ("paragraph" if f.tag == "textarea" else "text"),
                is_sensitive=is_sens,
                options=f.options
            ))
        return results

    async def resolve_profile_fields(self, classified_fields: List[ClassifiedField], user_profile: Dict[str, str]) -> List[ResolvedFieldStatus]:
        resolved_results = []
        for field in classified_fields:
            if field.is_sensitive:
                resolved_results.append(ResolvedFieldStatus(field_id=field.field_id, semantic_key=field.semantic_key, label_detected=field.label_detected, status="sensitive_blocked", raw_profile_value=None, options=field.options, expected_format=field.expected_format))
                continue
            
            # Reconnaissance instantanée et parfaite avec SQLite
            matched = False
            for k, v in user_profile.items():
                if k == field.semantic_key or field.semantic_key in k:
                    resolved_results.append(ResolvedFieldStatus(field_id=field.field_id, semantic_key=field.semantic_key, label_detected=field.label_detected, status="resolved", raw_profile_value=v, options=field.options, expected_format=field.expected_format))
                    matched = True
                    break
            
            if not matched:
                resolved_results.append(ResolvedFieldStatus(field_id=field.field_id, semantic_key=field.semantic_key, label_detected=field.label_detected, status="missing_information", raw_profile_value=None, options=field.options, expected_format=field.expected_format))
        
        return resolved_results

    async def generate_missing_info_questions(self, missing_fields: List[ResolvedFieldStatus]) -> List[MissingInfoQuestion]:
        # Demande la donnée à l'utilisateur instantanément
        return [MissingInfoQuestion(
            field_id=f.field_id, semantic_key=f.semantic_key,
            question_fr=f"Quelle valeur souhaitez-vous pour « {f.label_detected} » ?",
            suggested_placeholder=""
        ) for f in missing_fields if f.status == "missing_information"]

    async def generate_final_field_values(self, resolved_fields: List[ResolvedFieldStatus], page_context: str = "") -> List[FilledFieldItem]:
        ready_fields = [f for f in resolved_fields if f.status == "resolved" and f.raw_profile_value]
        if not ready_fields: return []
        
        direct_filled = []
        llm_targets = []
        
        # Séparation : Injection directe vs. Formatage IA
        for rf in ready_fields:
            if rf.options or rf.expected_format == "paragraph" or len(rf.raw_profile_value) > 100:
                llm_targets.append(rf) # Seulement pour les menus déroulants et les rédactions
            else:
                direct_filled.append(FilledFieldItem(field_id=rf.field_id, semantic_key=rf.semantic_key, final_value=rf.raw_profile_value.strip(), confidence=1.0))
        
        if not llm_targets: return direct_filled

        try:
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
        except Exception as e:
            print(f"[LLM FILL ERROR] {e}")
            
        return direct_filled
EOF
echo "✅ Architecture Hybride locale déployée !"