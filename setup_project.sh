#!/bin/bash

# Nom du dossier racine
PROJECT_DIR="chrome-form-filler"

echo "🚀 Création du projet $PROJECT_DIR..."

# 1. Création de l'arborescence des dossiers
mkdir -p "$PROJECT_DIR/extension/popup"
mkdir -p "$PROJECT_DIR/backend/app/api"
mkdir -p "$PROJECT_DIR/backend/app/agents/form_analyzer"
mkdir -p "$PROJECT_DIR/backend/app/agents/field_classifier"
mkdir -p "$PROJECT_DIR/backend/app/agents/profile_resolver"
mkdir -p "$PROJECT_DIR/backend/app/agents/missing_info"
mkdir -p "$PROJECT_DIR/backend/app/agents/form_filler"
mkdir -p "$PROJECT_DIR/backend/app/llm"
mkdir -p "$PROJECT_DIR/backend/app/storage"
mkdir -p "$PROJECT_DIR/backend/app/models"

# Création des fichiers __init__.py vides
touch "$PROJECT_DIR/backend/app/__init__.py"
touch "$PROJECT_DIR/backend/app/api/__init__.py"
touch "$PROJECT_DIR/backend/app/agents/__init__.py"
touch "$PROJECT_DIR/backend/app/llm/__init__.py"
touch "$PROJECT_DIR/backend/app/storage/__init__.py"
touch "$PROJECT_DIR/backend/app/models/__init__.py"

# --- FICHIERS RACINE ---

echo "📄 Création des fichiers de configuration racine et Docker..."

cat << 'EOF' > "$PROJECT_DIR/.gitignore"
# Environnement et secrets
.env
backend/.env
*.env

# Python
__pycache__/
*.py[cod]
*$py.class
venv/
.venv/

# Base de données locale SQLite
data/
*.db
*.sqlite3

# OS / IDE
.DS_Store
.vscode/
.idea/
EOF

cat << 'EOF' > "$PROJECT_DIR/Dockerfile"
FROM python:3.11-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/app ./app
RUN mkdir -p /app/data

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
EOF

cat << 'EOF' > "$PROJECT_DIR/docker-compose.yml"
services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: chrome_form_filler_backend
    ports:
      - "8000:8000"
    environment:
      - GROQ_API_KEY=${GROQ_API_KEY:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - LLM_PROVIDER=${LLM_PROVIDER:-groq}
      - GROQ_MODEL=${GROQ_MODEL:-llama-3.3-70b-versatile}
      - OPENAI_MODEL=${OPENAI_MODEL:-gpt-4o-mini}
      - DATABASE_URL=${DATABASE_URL:-sqlite:////app/data/profile.db}
    volumes:
      - sqlite_data:/app/data
      - ./backend/app:/app/app
    restart: unless-stopped

volumes:
  sqlite_data:
EOF

cat << 'EOF' > "$PROJECT_DIR/README.md"
# AI Form Filler — Extension Chrome & Architecture Multi-Agents (Groq / OpenAI)
Projet complet d'extension Chrome avec un backend FastAPI multi-agents.
Veuillez vous référer à la documentation complète pour les instructions de lancement.
EOF

# --- FICHIERS BACKEND ---

echo "📄 Création des fichiers du Backend Python..."

cat << 'EOF' > "$PROJECT_DIR/backend/.env.example"
GROQ_API_KEY=gsk_votre_cle_groq_ici
OPENAI_API_KEY=sk-votre_cle_openai_ici
LLM_PROVIDER=groq
GROQ_MODEL=llama-3.3-70b-versatile
OPENAI_MODEL=gpt-4o-mini
DATABASE_URL=sqlite:///./data/profile.db
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/requirements.txt"
fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.9.2
pydantic-settings==2.5.2
sqlalchemy==2.0.35
httpx==0.27.2
python-dotenv==1.0.1
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/config.py"
import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

class Settings:
    GROQ_API_KEY: str = os.getenv("GROQ_API_KEY", "")
    OPENAI_API_KEY: str = os.getenv("OPENAI_API_KEY", "")
    LLM_PROVIDER: str = os.getenv("LLM_PROVIDER", "groq").lower()
    GROQ_MODEL: str = os.getenv("GROQ_MODEL", "llama-3.3-70b-versatile")
    OPENAI_MODEL: str = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
    DATABASE_URL: str = os.getenv("DATABASE_URL", "sqlite:///./data/profile.db")
    AGENTS_DIR: Path = Path(__file__).resolve().parent / "agents"

settings = Settings()
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/models/schemas.py"
from typing import List, Optional, Dict, Any
from pydantic import BaseModel, Field

class RawDOMField(BaseModel):
    field_id: str
    tag: str
    input_type: str = "text"
    name: Optional[str] = ""
    dom_id: Optional[str] = ""
    label: Optional[str] = ""
    placeholder: Optional[str] = ""
    surrounding_text: Optional[str] = ""
    options: Optional[List[str]] = Field(default_factory=list)
    required: bool = False
    is_sensitive: bool = False

class AnalyzeFormRequest(BaseModel):
    url: Optional[str] = ""
    page_title: Optional[str] = ""
    fields: List[RawDOMField]
    provider: Optional[str] = None
    model: Optional[str] = None

class ClassifiedField(BaseModel):
    field_id: str
    label_detected: str
    semantic_key: str
    category: str
    expected_format: str = "text"
    is_sensitive: bool = False
    options: List[str] = Field(default_factory=list)
    context_summary: str = ""

class AnalyzeFormResponse(BaseModel):
    classified_fields: List[ClassifiedField]

class ResolveFieldsRequest(BaseModel):
    classified_fields: List[ClassifiedField]
    provider: Optional[str] = None
    model: Optional[str] = None

class ResolvedFieldStatus(BaseModel):
    field_id: str
    semantic_key: str
    label_detected: str
    status: str
    raw_profile_value: Optional[str] = None
    context_summary: str = ""
    expected_format: str = "text"
    options: List[str] = Field(default_factory=list)

class ResolveFieldsResponse(BaseModel):
    resolved_fields: List[ResolvedFieldStatus]

class MissingInfoRequest(BaseModel):
    missing_fields: List[ResolvedFieldStatus]
    provider: Optional[str] = None
    model: Optional[str] = None

class MissingInfoQuestion(BaseModel):
    field_id: str
    semantic_key: str
    question_fr: str
    suggested_placeholder: str = ""

class MissingInfoResponse(BaseModel):
    questions: List[MissingInfoQuestion]

class SaveInfoItem(BaseModel):
    key: str
    value: str
    category: Optional[str] = "general"
    confirmed_by_user: bool = True

class SaveInfoRequest(BaseModel):
    items: List[SaveInfoItem]

class FillFieldsRequest(BaseModel):
    resolved_fields: List[ResolvedFieldStatus]
    page_context: Optional[str] = ""
    provider: Optional[str] = None
    model: Optional[str] = None

class FilledFieldItem(BaseModel):
    field_id: str
    semantic_key: str
    final_value: str
    confidence: float = 1.0

class FillFieldsResponse(BaseModel):
    filled_fields: List[FilledFieldItem]

class LLMSettingsUpdate(BaseModel):
    provider: str
    model: str
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/storage/database.py"
import os
from sqlalchemy import create_engine, Column, String, Text, DateTime
from sqlalchemy.orm import declarative_base, sessionmaker
from datetime import datetime, timezone
from app.config import settings

if settings.DATABASE_URL.startswith("sqlite:///"):
    db_path = settings.DATABASE_URL.replace("sqlite:///", "")
    db_dir = os.path.dirname(db_path)
    if db_dir and not os.path.exists(db_dir):
        os.makedirs(db_dir, exist_ok=True)

engine = create_engine(
    settings.DATABASE_URL,
    connect_args={"check_same_thread": False} if "sqlite" in settings.DATABASE_URL else {}
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

class UserProfileEntry(Base):
    __tablename__ = "user_profile"

    key = Column(String(120), primary_key=True, index=True)
    value = Column(Text, nullable=False)
    category = Column(String(60), default="general")
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

def init_db():
    Base.metadata.create_all(bind=engine)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/storage/user_profile.py"
from typing import Dict, List, Optional
from sqlalchemy.orm import Session
from app.storage.database import UserProfileEntry

DEFAULT_USER_PROFILE = [
    {"key": "first_name", "value": "Iyad", "category": "personal"},
    {"key": "last_name", "value": "Hadifé", "category": "personal"},
    {"key": "full_name", "value": "Iyad Hadifé", "category": "personal"},
    {"key": "email", "value": "iyad.hadife@edu.devinci.fr", "category": "contact"},
    {"key": "phone", "value": "+33 6 10 52 10 62", "category": "contact"},
    {"key": "city", "value": "Puteaux", "category": "address"},
    {"key": "postal_code", "value": "92800", "category": "address"},
    {"key": "country", "value": "France", "category": "address"},
    {"key": "portfolio_url", "value": "https://iyad-hadife.com", "category": "social"},
    {"key": "linkedin_url", "value": "https://www.linkedin.com/in/iyad-hadife", "category": "social"},
    {"key": "job_title", "value": "Ingénieur Data et IA", "category": "professional"},
    {"key": "availability", "value": "Disponible immédiatement en CDI", "category": "professional"},
    {"key": "education_degree", "value": "Master of Science en Data et Intelligence Artificielle (2023-2026)", "category": "education"},
    {"key": "education_school", "value": "ESILV (École Supérieure d'Ingénieurs Léonard de Vinci)", "category": "education"},
    {
        "key": "experience_summary",
        "value": (
            "Stage Ingénieur Data/IA chez Dassault Systèmes (Fév 2026 - Août 2026 : orchestrateur multi-agents LangGraph/LangChain/MCP, "
            "Deep Learning géométrique GNN sous PyTorch et extraction CAO CATIA). "
            "Stage Data Scientist & Data Engineer chez SFR (Avr 2025 - Août 2025 : détection d'anomalies réseau par GNN, MLOps GitLab/Jenkins, RAG local Flask). "
            "Stage Développeur et Testeur IA chez Spacefit.ai (Déc 2023 - Fév 2024)."
        ),
        "category": "experience"
    },
    {
        "key": "technical_skills",
        "value": (
            "Python, SQL, PySpark, C#, C++, R, PyTorch, PyTorch Geometric, TensorFlow, Scikit-Learn, "
            "LangGraph, LangChain, RAG, MCP (FastMCP), FastAPI, Flask, Django, React, Docker, Kubernetes, GCP, Git, Jenkins, CATIA 3DEXPERIENCE"
        ),
        "category": "skills"
    },
    {
        "key": "languages",
        "value": "Français (langue maternelle), Anglais (professionnel, TOEIC B2+)",
        "category": "skills"
    },
    {
        "key": "short_bio",
        "value": (
            "Ingénieur Data et IA diplômé de l'ESILV. Des réseaux de neurones sur graphes aux architectures multi-agents, "
            "je transforme des données industrielles brutes en modèles qui automatisent des tâches manuelles."
        ),
        "category": "professional"
    }
]

def seed_default_profile(db: Session) -> None:
    count = db.query(UserProfileEntry).count()
    if count == 0:
        for item in DEFAULT_USER_PROFILE:
            db.add(UserProfileEntry(**item))
        db.commit()

def get_all_profile_dict(db: Session) -> Dict[str, str]:
    entries = db.query(UserProfileEntry).all()
    return {e.key: e.value for e in entries}

def get_all_profile_entries(db: Session) -> List[Dict[str, str]]:
    entries = db.query(UserProfileEntry).order_by(UserProfileEntry.category, UserProfileEntry.key).all()
    return [
        {
            "key": e.key,
            "value": e.value,
            "category": e.category,
            "updated_at": e.updated_at.isoformat() if e.updated_at else ""
        }
        for e in entries
    ]

def upsert_profile_entry(db: Session, key: str, value: str, category: str = "general") -> UserProfileEntry:
    clean_key = key.strip().lower().replace(" ", "_")
    entry = db.query(UserProfileEntry).filter(UserProfileEntry.key == clean_key).first()
    if entry:
        entry.value = value.strip()
        if category:
            entry.category = category
    else:
        entry = UserProfileEntry(key=clean_key, value=value.strip(), category=category)
        db.add(entry)
    db.commit()
    db.refresh(entry)
    return entry

def delete_profile_entry(db: Session, key: str) -> bool:
    entry = db.query(UserProfileEntry).filter(UserProfileEntry.key == key).first()
    if not entry:
        return False
    db.delete(entry)
    db.commit()
    return True
EOF

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
            "temperature": 0.1,
            "response_format": {"type": "json_object"}
        }
        async with httpx.AsyncClient(timeout=45.0) as client:
            response = await client.post(self.BASE_URL, headers=headers, json=payload)
            if response.status_code != 200:
                raise RuntimeError(f"Erreur API Groq: {response.text}")
            return json.loads(response.json()["choices"][0]["message"]["content"])
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/llm/openai_client.py"
import json
import httpx
from typing import Dict, Any, Optional
from app.config import settings

class OpenAIClient:
    BASE_URL = "https://api.openai.com/v1/chat/completions"

    def __init__(self, api_key: Optional[str] = None, model: Optional[str] = None):
        self.api_key = api_key or settings.OPENAI_API_KEY
        self.model = model or settings.OPENAI_MODEL

    async def generate_json(self, system_prompt: str, user_payload: Dict[str, Any]) -> Dict[str, Any]:
        if not self.api_key:
            raise ValueError("Clé API OpenAI manquante.")
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
                raise RuntimeError(f"Erreur API OpenAI: {response.text}")
            return json.loads(response.json()["choices"][0]["message"]["content"])
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/form_analyzer/skill.md"
# Agent: Form Analyzer Agent
## Rôle
Tu es un agent expert en analyse structurelle de formulaires DOM web. Ton objectif est d'inspecter les métadonnées brutes extraites d'une page web et de nettoyer et synthétiser le contexte de chaque champ.
## Sorties
Un objet JSON contenant la clé `analyzed_fields` avec `field_id`, `clean_label`, `context_summary`, `is_sensitive`.
## Règles à suivre
1. Ne jamais modifier le `field_id`.
2. Détecte systématiquement les champs sensibles pour bloquer tout remplissage automatique non autorisé.
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/field_classifier/skill.md"
# Agent: Field Classifier Agent
## Rôle
Tu es un agent de classification sémantique de champs de formulaires. À partir des champs analysés, tu détermines la clé sémantique normalisée (`semantic_key`), la catégorie et le format attendu.
## Sorties
Un objet JSON contenant la clé `classified_fields`.
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/profile_resolver/skill.md"
# Agent: Profile Resolver Agent
## Rôle
Tu es un agent de résolution de données personnelles. Ta mission est d'associer chaque champ classifié à la donnée correspondante dans le profil utilisateur enregistré, ou de déclarer l'information comme manquante (`missing_information`).
## Sorties
Un objet JSON contenant `resolved_fields` avec le statut `resolved`, `missing_information`, ou `sensitive_blocked`.
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/missing_info/skill.md"
# Agent: Missing Info Agent
## Rôle
Tu es un agent chargé d'interagir avec l'utilisateur lorsqu'une information nécessaire au remplissage d'un formulaire est absente de son profil local. Tu formules une question claire, concise et naturelle en français.
## Sorties
Un objet JSON contenant la clé `questions`.
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/agents/form_filler/skill.md"
# Agent: Form Filler Agent
## Rôle
Tu es un agent rédacteur et formateur de champs web. Tu reçois les champs résolus accompagnés uniquement des données nécessaires issues du profil utilisateur, et tu génères la valeur exacte à insérer.
## Sorties
Un objet JSON contenant `filled_fields`.
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
        analyzer_input = {"url": url, "page_title": page_title, "fields": [f.model_dump() for f in raw_fields]}
        analyzer_output = await llm.generate_json(analyzer_prompt, analyzer_input)
        
        enriched_analyzed = [{"field_id": f.get("field_id")} for f in analyzer_output.get("analyzed_fields", [])]
        
        classifier_prompt = self.load_skill_prompt("field_classifier")
        classifier_input = {"analyzed_fields": enriched_analyzed, "available_profile_keys": available_profile_keys}
        classifier_output = await llm.generate_json(classifier_prompt, classifier_input)
        
        results = []
        for c in classifier_output.get("classified_fields", []):
            results.append(ClassifiedField(
                field_id=c.get("field_id", ""),
                label_detected=c.get("label_detected", ""),
                semantic_key=c.get("semantic_key", "unknown"),
                category=c.get("category", "general"),
                expected_format=c.get("expected_format", "text"),
                is_sensitive=bool(c.get("is_sensitive", False))
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
        resolver_input = {"classified_fields": [f.model_dump() for f in fields_needing_llm], "profile_keys_and_values": user_profile}
        resolver_output = await llm.generate_json(resolver_prompt, resolver_input)
        
        for item in resolver_output.get("resolved_fields", []):
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
        ) for q in output.get("questions", [])]

    async def generate_final_field_values(self, resolved_fields: List[ResolvedFieldStatus], page_context: str = "") -> List[FilledFieldItem]:
        ready_fields = [f for f in resolved_fields if f.status == "resolved" and f.raw_profile_value]
        if not ready_fields: return []
        direct_filled = []
        llm_targets = ready_fields 
        llm = self._get_llm_client()
        filler_prompt = self.load_skill_prompt("form_filler")
        output = await llm.generate_json(filler_prompt, {"page_context": page_context, "fields_to_fill": [f.model_dump() for f in llm_targets]})
        
        for item in output.get("filled_fields", []):
            direct_filled.append(FilledFieldItem(
                field_id=item.get("field_id", ""), semantic_key=item.get("semantic_key", ""),
                final_value=str(item.get("final_value", "")), confidence=float(item.get("confidence", 1.0))
            ))
        return direct_filled
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/api/routes.py"
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app.config import settings
from app.storage.database import get_db
from app.storage.user_profile import get_all_profile_dict, get_all_profile_entries, upsert_profile_entry, delete_profile_entry
from app.models.schemas import AnalyzeFormRequest, AnalyzeFormResponse, ResolveFieldsRequest, ResolveFieldsResponse, MissingInfoRequest, MissingInfoResponse, SaveInfoRequest, FillFieldsRequest, FillFieldsResponse, LLMSettingsUpdate
from app.agents.orchestrator import AgentOrchestrator

router = APIRouter()

@router.get("/health")
async def health_check():
    return {"status": "ok", "llm_provider": settings.LLM_PROVIDER, "groq_model": settings.GROQ_MODEL, "openai_model": settings.OPENAI_MODEL}

@router.put("/settings")
async def update_llm_settings(payload: LLMSettingsUpdate):
    settings.LLM_PROVIDER = payload.provider.lower().strip()
    if settings.LLM_PROVIDER == "groq": settings.GROQ_MODEL = payload.model
    else: settings.OPENAI_MODEL = payload.model
    return {"status": "updated"}

@router.get("/profile")
async def get_profile(db: Session = Depends(get_db)):
    return {"profile": get_all_profile_entries(db)}

@router.post("/save-info")
async def save_user_info(request: SaveInfoRequest, db: Session = Depends(get_db)):
    for item in request.items:
        if item.confirmed_by_user and item.key.strip():
            upsert_profile_entry(db, key=item.key, value=item.value, category=item.category or "general")
    return {"status": "saved"}

@router.delete("/profile/{key}")
async def remove_profile_entry(key: str, db: Session = Depends(get_db)):
    delete_profile_entry(db, key)
    return {"status": "deleted"}

@router.post("/analyze-form", response_model=AnalyzeFormResponse)
async def analyze_form(request: AnalyzeFormRequest, db: Session = Depends(get_db)):
    orchestrator = AgentOrchestrator(provider=request.provider, model=request.model)
    classified = await orchestrator.analyze_and_classify(request.url or "", request.page_title or "", request.fields, list(get_all_profile_dict(db).keys()))
    return AnalyzeFormResponse(classified_fields=classified)

@router.post("/resolve-fields", response_model=ResolveFieldsResponse)
async def resolve_fields(request: ResolveFieldsRequest, db: Session = Depends(get_db)):
    orchestrator = AgentOrchestrator(provider=request.provider, model=request.model)
    resolved = await orchestrator.resolve_profile_fields(request.classified_fields, get_all_profile_dict(db))
    return ResolveFieldsResponse(resolved_fields=resolved)

@router.post("/missing-info", response_model=MissingInfoResponse)
async def handle_missing_info(request: MissingInfoRequest):
    orchestrator = AgentOrchestrator(provider=request.provider, model=request.model)
    questions = await orchestrator.generate_missing_info_questions(request.missing_fields)
    return MissingInfoResponse(questions=questions)

@router.post("/fill-fields", response_model=FillFieldsResponse)
async def fill_fields(request: FillFieldsRequest):
    orchestrator = AgentOrchestrator(provider=request.provider, model=request.model)
    filled = await orchestrator.generate_final_field_values(request.resolved_fields, request.page_context or "")
    return FillFieldsResponse(filled_fields=filled)
EOF

cat << 'EOF' > "$PROJECT_DIR/backend/app/main.py"
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.api.routes import router
from app.storage.database import init_db, SessionLocal
from app.storage.user_profile import seed_default_profile

@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    db = SessionLocal()
    try:
        seed_default_profile(db)
    finally:
        db.close()
    yield

app = FastAPI(title="Chrome Form Filler API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)
EOF

# --- FICHIERS EXTENSION CHROME ---

echo "📄 Création des fichiers de l'Extension Chrome..."

cat << 'EOF' > "$PROJECT_DIR/extension/manifest.json"
{
  "manifest_version": 3,
  "name": "AI Form Filler",
  "version": "1.0.0",
  "permissions": ["activeTab", "scripting", "storage"],
  "host_permissions": ["http://localhost:8000/*"],
  "background": { "service_worker": "background.js" },
  "action": { "default_popup": "popup/popup.html" },
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ]
}
EOF

cat << 'EOF' > "$PROJECT_DIR/extension/background.js"
const BACKEND_URL = "http://localhost:8000";
chrome.runtime.onInstalled.addListener(() => {
  console.log("[AI Form Filler] Installé.");
});
EOF

cat << 'EOF' > "$PROJECT_DIR/extension/content.js"
(() => {
  const fieldRegistry = new Map();
  function scanFormFields() {
    fieldRegistry.clear();
    const elements = document.querySelectorAll("input, textarea, select");
    const extractedFields = [];
    let counter = 0;
    elements.forEach((el) => {
      if (el.disabled || el.readOnly || el.type === "hidden") return;
      const fieldId = `f_${counter++}`;
      fieldRegistry.set(fieldId, el);
      el.setAttribute("data-ai-field-id", fieldId);
      extractedFields.push({
        field_id: fieldId, tag: el.tagName.toLowerCase(), input_type: el.type,
        name: el.name || "", dom_id: el.id || "", label: "",
        placeholder: el.placeholder || ""
      });
    });
    return { url: window.location.href, page_title: document.title, fields: extractedFields };
  }
  function setNativeValue(element, value) {
    element.value = value;
    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }
  chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "SCAN_PAGE") {
      sendResponse({ ok: true, data: scanFormFields() });
    } else if (request.action === "FILL_MULTIPLE_FIELDS") {
      (request.items || []).forEach((item) => {
        const el = fieldRegistry.get(item.field_id);
        if (el) setNativeValue(el, item.value);
      });
      sendResponse({ ok: true });
    }
    return true;
  });
})();
EOF

cat << 'EOF' > "$PROJECT_DIR/extension/popup/popup.html"
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8" />
  <link rel="stylesheet" href="popup.css" />
</head>
<body>
  <h2>AI Form Filler</h2>
  <button id="btn-scan">Scanner la page</button>
  <button id="btn-fill-all">Tout remplir</button>
  <div id="status-message"></div>
  <script src="popup.js"></script>
</body>
</html>
EOF

cat << 'EOF' > "$PROJECT_DIR/extension/popup/popup.css"
body { width: 300px; padding: 10px; font-family: sans-serif; }
button { width: 100%; margin-bottom: 10px; padding: 8px; }
EOF

cat << 'EOF' > "$PROJECT_DIR/extension/popup/popup.js"
const API_BASE = "http://localhost:8000";
document.getElementById("btn-scan").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const domResponse = await chrome.tabs.sendMessage(tab.id, { action: "SCAN_PAGE" });
  if(domResponse && domResponse.data) {
    document.getElementById("status-message").innerText = "Champs détectés : " + domResponse.data.fields.length;
  }
});
EOF

echo "✅ Succès ! L'architecture complète a été générée dans le dossier '$PROJECT_DIR'."
echo "➡️  Exécutez 'cd $PROJECT_DIR' puis lancez 'docker compose up --build -d' pour démarrer."