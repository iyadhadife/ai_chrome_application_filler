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
