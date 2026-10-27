#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 9 : Bypass total des iFrames Cross-Origin (Workday/Taleo)..."

cat << 'EOF' > "$PROJECT_DIR/extension/popup/popup.js"
const API_BASE = "http://localhost:8000";
let resolvedState = [];
let valuesMap = {};
let allDetectedFields = [];
let frameMapping = {}; // Mémorise dans quelle iFrame exacte se trouve chaque champ

function setStatus(text) { document.getElementById("status-message").innerText = text; }

// --- 1. FONCTION INJECTÉE DE FORCE DANS TOUS LES CADRES PAR CHROME ---
function DOM_SCANNER() {
  const IGNORED_INPUT_TYPES = new Set(["submit", "button", "reset", "image", "file", "checkbox", "radio"]);
  
  function findElementsDeep(root) {
    let elements = [];
    try {
      const allNodes = root.querySelectorAll('*');
      for (const el of allNodes) {
        const tag = el.tagName.toLowerCase();
        // Capture des inputs classiques + Divs éditables (Workday) + ARIA Textboxes
        if (tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable || el.getAttribute('role') === 'textbox') elements.push(el);
        if (el.shadowRoot) elements = elements.concat(findElementsDeep(el.shadowRoot));
      }
    } catch (e) {}
    return elements;
  }

  function extractLabel(el) {
    try {
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
    } catch(e) {}
    return "";
  }

  let elements = findElementsDeep(document);
  const extractedFields = [];
  let counter = 0;
  
  // Génère un ID unique pour ce cadre spécifique
  const frameUniq = Math.random().toString(36).substring(2, 9);

  elements.forEach((el) => {
    if (el.disabled || el.readOnly) return;
    const tag = el.tagName.toLowerCase();
    const inputType = (el.getAttribute("type") || (tag === "select" ? "select-one" : "text")).toLowerCase();
    
    if (tag === "input" && IGNORED_INPUT_TYPES.has(inputType)) return;

    const name = (el.getAttribute("name") || "").toLowerCase();
    const domId = (el.id || "").toLowerCase();
    
    if (inputType === "hidden") {
       if (name.includes("csrf") || name.includes("token") || name.includes("state") || name.includes("__") || domId.includes("csrf")) return;
       if (!name && !domId) return;
    }

    const fieldId = `f_${frameUniq}_${counter++}`;
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

// --- 2. FONCTION INJECTÉE POUR LE REMPLISSAGE FINAL ---
function DOM_FILLER(items) {
  function setNativeValue(element, value) {
    const tag = element.tagName.toLowerCase();
    element.focus();
    element.click();
    
    if(element.isContentEditable || element.getAttribute('role') === 'textbox' && tag !== 'input' && tag !== 'textarea') {
       element.innerText = value;
    } else if (tag === "select") {
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

    const events = ['keydown', 'keypress', 'input', 'keyup', 'change', 'blur'];
    events.forEach(eventType => {
      element.dispatchEvent(new Event(eventType, { bubbles: true, composed: true, cancelable: true }));
    });

    const originalBg = element.style.backgroundColor;
    element.style.backgroundColor = "#dcfce7";
    setTimeout(() => { element.style.backgroundColor = originalBg; }, 1500);
  }

  let filled = 0;
  items.forEach(item => {
    const el = document.querySelector(`[data-ai-field-id="${item.field_id}"]`);
    if(el) { setNativeValue(el, item.value); filled++; }
  });
  return filled;
}

// --- 3. LOGIQUE DU POPUP ---
document.getElementById("btn-scan").addEventListener("click", async () => {
  const btn = document.getElementById("btn-scan");
  btn.disabled = true;
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    setStatus("Exploration réseau (iFrames Cross-Origin)...");
    
    // Le pouvoir magique : on exécute le script sur TOUTES les frames du navigateur instantanément
    const results = await chrome.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      func: DOM_SCANNER
    });

    allDetectedFields = [];
    frameMapping = {};
    let mainTitle = "";
    let mainUrl = "";

    results.forEach(frameResult => {
      if (frameResult.result && frameResult.result.fields && frameResult.result.fields.length > 0) {
         const fData = frameResult.result;
         mainTitle = mainTitle || fData.page_title;
         mainUrl = mainUrl || fData.url;
         fData.fields.forEach(f => {
           allDetectedFields.push(f);
           frameMapping[f.field_id] = frameResult.frameId; // On lie le champ à son iFrame spécifique
         });
      }
    });

    if (allDetectedFields.length === 0) {
      setStatus("Aucun champ trouvé, même dans les cadres virtuels."); btn.disabled = false; return;
    }

    setStatus(`IA Groq: Analyse de ${allDetectedFields.length} champs...`);
    const payload = { url: mainUrl, page_title: mainTitle, fields: allDetectedFields };
    
    const resAnalyze = await fetch(`${API_BASE}/analyze-form`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const dataAnalyze = await resAnalyze.json();

    setStatus("Recherche dans votre profil local...");
    const resResolve = await fetch(`${API_BASE}/resolve-fields`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ classified_fields: dataAnalyze.classified_fields })
    });
    const dataResolve = await resResolve.json();
    resolvedState = dataResolve.resolved_fields;

    setStatus("Génération des textes...");
    const resFill = await fetch(`${API_BASE}/fill-fields`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resolved_fields: resolvedState, page_context: mainTitle })
    });
    const dataFill = await resFill.json();
    
    valuesMap = {};
    dataFill.filled_fields.forEach(item => valuesMap[item.field_id] = item.final_value);
    
    renderFields();
    setStatus(`Prêt : ${Object.keys(valuesMap).length} champs résolus sur ${allDetectedFields.length}.`);
    document.getElementById("btn-fill-all").disabled = false;
  } catch (err) {
    setStatus(`Erreur: ${err.message}`);
  }
  btn.disabled = false;
});

document.getElementById("btn-fill-all").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  setStatus("Remplissage ciblé en cours...");
  
  const itemsByFrame = {};
  Object.keys(valuesMap).forEach(fid => {
    const fId = frameMapping[fid];
    if(!itemsByFrame[fId]) itemsByFrame[fId] = [];
    itemsByFrame[fId].push({ field_id: fid, value: valuesMap[fid] });
  });

  // On renvoie les valeurs uniquement vers l'iFrame propriétaire de chaque champ
  for (const [frameIdStr, items] of Object.entries(itemsByFrame)) {
    const frameId = parseInt(frameIdStr, 10);
    await chrome.scripting.executeScript({
      target: { tabId: tab.id, frameIds: [frameId] },
      func: DOM_FILLER,
      args: [items]
    });
  }
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
    card.innerHTML = `<span class="field-label">${f.label_detected} (${f.semantic_key})</span><input type="text" id="inp_${f.field_id}" value="${val.replace(/"/g, '&quot;')}" />`;
    card.querySelector("input").addEventListener("input", (e) => valuesMap[f.field_id] = e.target.value);
    list.appendChild(card);
  });
}
EOF
echo "✅ Logique de Contournement d'iFrames Cross-Origin (Workday/Taleo) déployée !"