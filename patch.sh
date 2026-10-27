#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Mise à jour des fichiers complets de l'extension..."

cat << 'EOF' > "$PROJECT_DIR/extension/content.js"
(() => {
  const fieldRegistry = new Map();
  const IGNORED_INPUT_TYPES = new Set(["hidden", "submit", "button", "reset", "image", "file", "checkbox", "radio"]);
  const SENSITIVE_PATTERNS = /password|mot de passe|cvv|cvc|card.?number|carte.?bancaire|iban|sécurité.?sociale|ssn|pin/i;

  function isVisible(el) {
    const style = window.getComputedStyle(el);
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0" && el.getBoundingClientRect().width > 0;
  }

  function extractLabel(el) {
    if (el.id) {
      const explicitLabel = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (explicitLabel && explicitLabel.innerText.trim()) return explicitLabel.innerText.trim();
    }
    const parentLabel = el.closest("label");
    if (parentLabel && parentLabel.innerText.trim()) return parentLabel.innerText.trim();
    const ariaLabel = el.getAttribute("aria-label");
    if (ariaLabel && ariaLabel.trim()) return ariaLabel.trim();
    const prev = el.previousElementSibling;
    if (prev && ["LABEL", "SPAN", "DIV", "P", "STRONG"].includes(prev.tagName)) return prev.innerText.trim();
    return "";
  }

  function scanFormFields() {
    fieldRegistry.clear();
    const elements = document.querySelectorAll("input, textarea, select");
    const extractedFields = [];
    let counter = 0;

    elements.forEach((el) => {
      if (el.disabled || el.readOnly || !isVisible(el)) return;
      const tag = el.tagName.toLowerCase();
      const inputType = (el.getAttribute("type") || (tag === "select" ? "select-one" : "text")).toLowerCase();
      if (tag === "input" && IGNORED_INPUT_TYPES.has(inputType)) return;

      const fieldId = `f_${counter++}`;
      fieldRegistry.set(fieldId, el);
      el.setAttribute("data-ai-field-id", fieldId);

      const label = extractLabel(el);
      const placeholder = el.getAttribute("placeholder") || "";
      const name = el.getAttribute("name") || "";
      
      let options = [];
      if (tag === "select") {
        options = Array.from(el.options).filter(opt => opt.value !== "" && !opt.disabled).map(opt => opt.text.trim() || opt.value.trim()).slice(0, 40);
      }

      const combinedMeta = `${label} ${placeholder} ${name} ${inputType}`;
      extractedFields.push({
        field_id: fieldId, tag, input_type: inputType, name, dom_id: el.id || "",
        label, placeholder, surrounding_text: "", options, required: el.required || false,
        is_sensitive: inputType === "password" || SENSITIVE_PATTERNS.test(combinedMeta)
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
    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }

  chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "SCAN_PAGE") {
      sendResponse({ ok: true, data: scanFormFields() });
    } else if (request.action === "FILL_SINGLE_FIELD") {
      const el = fieldRegistry.get(request.field_id);
      if (el) { setNativeValue(el, request.value); sendResponse({ ok: true }); }
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
  <title>AI Form Filler</title>
  <style>
    body { width: 350px; font-family: system-ui, sans-serif; background: #0f172a; color: #f8fafc; padding: 15px; margin: 0; }
    h2 { font-size: 16px; margin-top: 0; border-bottom: 1px solid #334155; padding-bottom: 10px; }
    .btn { background: #3b82f6; color: white; border: none; padding: 10px; width: 100%; border-radius: 6px; cursor: pointer; margin-bottom: 10px; font-weight: bold; }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-success { background: #10b981; }
    #status-message { font-size: 12px; margin-bottom: 15px; color: #93c5fd; }
    .field-card { background: #1e293b; padding: 10px; border-radius: 6px; margin-bottom: 10px; border: 1px solid #334155; }
    .field-label { font-size: 12px; font-weight: bold; margin-bottom: 6px; display: block; }
    input, textarea { width: 100%; box-sizing: border-box; background: #0f172a; border: 1px solid #334155; color: white; padding: 6px; border-radius: 4px; font-size: 12px; }
    .btn-small { margin-top: 6px; padding: 6px; font-size: 11px; margin-bottom: 0; }
  </style>
</head>
<body>
  <h2>AI Form Filler</h2>
  <button id="btn-scan" class="btn">1. Scanner la page</button>
  <button id="btn-fill-all" class="btn btn-success" disabled>2. Tout remplir</button>
  <div id="status-message">Prêt. Ouvrez une page avec un formulaire.</div>
  <div id="fields-list"></div>
  <script src="popup.js"></script>
</body>
</html>
EOF

cat << 'EOF' > "$PROJECT_DIR/extension/popup/popup.js"
const API_BASE = "http://localhost:8000";
let resolvedState = [];
let valuesMap = {};

function setStatus(text) { document.getElementById("status-message").innerText = text; }

document.getElementById("btn-scan").addEventListener("click", async () => {
  const btn = document.getElementById("btn-scan");
  btn.disabled = true;
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    setStatus("Extraction des champs...");
    const resDOM = await chrome.tabs.sendMessage(tab.id, { action: "SCAN_PAGE" });
    
    if (!resDOM || !resDOM.data || resDOM.data.fields.length === 0) {
      setStatus("Aucun champ trouvé."); btn.disabled = false; return;
    }

    const payload = resDOM.data;
    
    // 1. Analyser et classifier
    setStatus("Analyse IA en cours (Groq)...");
    const resAnalyze = await fetch(`${API_BASE}/analyze-form`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const dataAnalyze = await resAnalyze.json();

    // 2. Résoudre avec SQLite
    setStatus("Résolution avec le profil local...");
    const resResolve = await fetch(`${API_BASE}/resolve-fields`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ classified_fields: dataAnalyze.classified_fields })
    });
    const dataResolve = await resResolve.json();
    resolvedState = dataResolve.resolved_fields;

    // 3. Générer les valeurs finales
    setStatus("Génération des textes finaux...");
    const resFill = await fetch(`${API_BASE}/fill-fields`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resolved_fields: resolvedState, page_context: payload.page_title })
    });
    const dataFill = await resFill.json();
    
    valuesMap = {};
    dataFill.filled_fields.forEach(item => valuesMap[item.field_id] = item.final_value);
    
    renderFields();
    setStatus(`Terminé. ${Object.keys(valuesMap).length} champs résolus.`);
    document.getElementById("btn-fill-all").disabled = false;
  } catch (err) {
    setStatus(`Erreur: ${err.message}`);
  }
  btn.disabled = false;
});

document.getElementById("btn-fill-all").addEventListener("click", async () => {
  const items = Object.keys(valuesMap).map(fid => ({ field_id: fid, value: valuesMap[fid] }));
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  await chrome.tabs.sendMessage(tab.id, { action: "FILL_MULTIPLE_FIELDS", items });
  setStatus("Formulaire rempli !");
});

function renderFields() {
  const list = document.getElementById("fields-list");
  list.innerHTML = "";
  resolvedState.forEach(f => {
    if (f.status === "sensitive_blocked" || f.status === "missing_information") return;
    const val = valuesMap[f.field_id] || "";
    const card = document.createElement("div");
    card.className = "field-card";
    card.innerHTML = `
      <span class="field-label">${f.label_detected} (${f.semantic_key})</span>
      <input type="text" id="inp_${f.field_id}" value="${val.replace(/"/g, '&quot;')}" />
    `;
    card.querySelector("input").addEventListener("input", (e) => valuesMap[f.field_id] = e.target.value);
    list.appendChild(card);
  });
}
EOF

echo "✅ Fichiers remplacés avec succès !"