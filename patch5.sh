#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 5 : Compatibilité totale ATS & Extension Tokens..."

cat << 'EOF' > "$PROJECT_DIR/extension/content.js"
(() => {
  const fieldRegistry = new Map();
  // Suppression de "hidden" pour capturer les champs masqués par le design de l'ATS
  const IGNORED_INPUT_TYPES = new Set(["submit", "button", "reset", "image", "file", "checkbox", "radio"]);

  function findElementsDeep(root) {
    let elements = [];
    const allNodes = root.querySelectorAll('*');
    for (const el of allNodes) {
      const tag = el.tagName.toLowerCase();
      if (tag === 'input' || tag === 'textarea' || tag === 'select') elements.push(el);
      if (el.shadowRoot) elements = elements.concat(findElementsDeep(el.shadowRoot));
    }
    return elements;
  }

  function extractLabel(el) {
    if (el.id) {
      const explicitLabel = el.getRootNode().querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (explicitLabel && explicitLabel.innerText.trim()) return explicitLabel.innerText.trim();
    }
    const parentLabel = el.closest("label");
    if (parentLabel && parentLabel.innerText.trim()) return parentLabel.innerText.trim();
    const ariaLabel = el.getAttribute("aria-label");
    if (ariaLabel && ariaLabel.trim()) return ariaLabel.trim();
    let prev = el.previousElementSibling;
    if (!prev && el.parentElement) prev = el.parentElement.previousElementSibling;
    if (prev && ["LABEL", "SPAN", "DIV", "P", "STRONG"].includes(prev.tagName)) return prev.innerText.trim();
    return "";
  }

  function scanFormFields() {
    fieldRegistry.clear();
    let elements = findElementsDeep(document);
    const extractedFields = [];
    let counter = 0;

    elements.forEach((el) => {
      if (el.disabled || el.readOnly) return;
      const tag = el.tagName.toLowerCase();
      const inputType = (el.getAttribute("type") || (tag === "select" ? "select-one" : "text")).toLowerCase();
      
      if (tag === "input" && IGNORED_INPUT_TYPES.has(inputType)) return;

      const name = (el.getAttribute("name") || "").toLowerCase();
      const domId = (el.id || "").toLowerCase();
      
      // Filtre anti-bruit strict pour éviter de surcharger l'IA avec la technique interne du site
      if (inputType === "hidden") {
         if (name.includes("csrf") || name.includes("token") || name.includes("state") || name.includes("__") || domId.includes("csrf")) return;
         if (!name && !domId) return;
      }

      const fieldId = `f_${counter++}`;
      fieldRegistry.set(fieldId, el);
      el.setAttribute("data-ai-field-id", fieldId);

      const label = extractLabel(el);
      let options = [];
      if (tag === "select") {
        options = Array.from(el.options)
          .filter(opt => opt.value !== "" && !opt.disabled)
          .map(opt => opt.text.trim() || opt.value.trim())
          .slice(0, 40);
      }

      extractedFields.push({
        field_id: fieldId, tag, input_type: inputType, name, dom_id: el.id || "",
        label, placeholder: el.getAttribute("placeholder") || "", surrounding_text: "", options, 
        required: el.required || false, is_sensitive: inputType === "password"
      });
    });
    return { url: window.location.href, page_title: document.title, fields: extractedFields };
  }

  function setNativeValue(element, value) {
    const tag = element.tagName.toLowerCase();
    if (tag === "select") {
      const normalizedTarget = value.trim().toLowerCase();
      let matched = false;
      for (const opt of element.options) {
        if (opt.value.trim().toLowerCase() === normalizedTarget || opt.text.trim().toLowerCase() === normalizedTarget) {
          element.value = opt.value; matched = true; break;
        }
      }
      if (!matched) element.value = value;
    } else {
      const prototype = tag === "textarea" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
      const valueSetter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
      if (valueSetter) valueSetter.call(element, value);
      else element.value = value;
    }
    element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    element.dispatchEvent(new Event("change", { bubbles: true, composed: true }));
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
            "max_tokens": 4096
        }
        async with httpx.AsyncClient(timeout=45.0) as client:
            response = await client.post(self.BASE_URL, headers=headers, json=payload)
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
                print(f"\n[ERREUR JSON] Impossible de parser la réponse: {content}\n")
                return {}
EOF
echo "✅ Patch 5 appliqué avec succès !"