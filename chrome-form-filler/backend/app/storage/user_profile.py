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
