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
