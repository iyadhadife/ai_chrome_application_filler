#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 13 : Décodeur Workday & Déverrouillage de l'UI..."

cat << 'EOF' > "$PROJECT_DIR/extension/popup/popup.js"
const API_BASE = "http://localhost:8000";
let resolvedState = [];
let valuesMap = {};
let allDetectedFields = [];
let frameMapping = {};

function setStatus(text) { document.getElementById("status-message").innerText = text; }

function DOM_SCANNER() {
  const IGNORED_INPUT_TYPES = new Set(["submit", "button", "reset", "image", "file", "checkbox", "radio"]);
  
  function findElementsDeep(root) {
    let elements = [];
    try {
      const allNodes = root.querySelectorAll('*');
      for (const el of allNodes) {
        const tag = el.tagName.toLowerCase();
        if (tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable || el.getAttribute('role') === 'textbox') elements.push(el);
        if (el.shadowRoot) elements = elements.concat(findElementsDeep(el.shadowRoot));
      }
    } catch (e) {}
    return elements;
  }

  function extractLabel(el) {
    try {
      // DÉCODEUR SPÉCIAL WORKDAY / TALES
      let text = el.getAttribute("aria-label") || el.getAttribute("data-automation-id") || el.getAttribute("name") || "";
      const ariaId = el.getAttribute("aria-labelledby");
      if (ariaId) {
        const labelEl = el.getRootNode().getElementById(ariaId);
        if (labelEl) text += " " + labelEl.innerText;
      }
      if (!text || text.length < 3) {
         // Si le champ est toujours muet, on lit le texte de la div parent
         const parent = el.closest('div[data-automation-id], .css-1j99l8b, li, tr, fieldset');
         if (parent) text += " " + parent.innerText.substring(0, 100);
      }
      return text.replace(/\s+/g, ' ').trim() || el.id;
    } catch(e) {}
    return "";
  }

  let elements = findElementsDeep(document);
  const extractedFields = [];
  let counter = 0;
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
      field_id: fieldId, tag, input_type: inputType, name, dom_id: domId,
      label, placeholder: el.getAttribute("placeholder") || "", surrounding_text: "", options, 
      required: el.required || false, is_sensitive: inputType === "password"
    });
  });
  
  return { url: window.location.href, page_title: document.title, fields: extractedFields };
}

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

    ['keydown', 'keypress', 'input', 'keyup', 'change', 'blur'].forEach(eventType => {
      element.dispatchEvent(new Event(eventType, { bubbles: true, composed: true, cancelable: true }));
    });

    const originalBg = element.style.backgroundColor;
    element.style.backgroundColor = "#dcfce7";
    setTimeout(() => { element.style.backgroundColor = originalBg; }, 1500);
  }

  let filled = 0;
  items.forEach(item => {
    if(!item.value) return; // Ignore les champs laissés vides
    const el = document.querySelector(`[data-ai-field-id="${item.field_id}"]`);
    if(el) { setNativeValue(el, item.value); filled++; }
  });
  return filled;
}

document.getElementById("btn-scan").addEventListener("click", async () => {
  const btn = document.getElementById("btn-scan");
  btn.disabled = true;
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    setStatus("Exploration réseau (Workday)...");
    
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
           frameMapping[f.field_id] = frameResult.frameId;
         });
      }
    });

    if (allDetectedFields.length === 0) {
      setStatus("Aucun champ trouvé."); btn.disabled = false; return;
    }

    setStatus(`Analyse backend de ${allDetectedFields.length} champs...`);
    const payload = { url: mainUrl, page_title: mainTitle, fields: allDetectedFields };
    
    const resAnalyze = await fetch(`${API_BASE}/analyze-form`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const dataAnalyze = await resAnalyze.json();

    setStatus("Résolution profil...");
    const resResolve = await fetch(`${API_BASE}/resolve-fields`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ classified_fields: dataAnalyze.classified_fields })
    });
    const dataResolve = await resResolve.json();
    resolvedState = dataResolve.resolved_fields;

    setStatus("Génération...");
    const resFill = await fetch(`${API_BASE}/fill-fields`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resolved_fields: resolvedState, page_context: mainTitle })
    });
    const dataFill = await resFill.json();
    
    valuesMap = {};
    dataFill.filled_fields.forEach(item => valuesMap[item.field_id] = item.final_value);
    
    renderFields();
    setStatus(`Prêt. Validez ou complétez la liste ci-dessous.`);
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
    // On bloque uniquement les mots de passe. TOUS les autres champs s'affichent !
    if (f.status === "sensitive_blocked") return;
    
    const val = valuesMap[f.field_id] || "";
    const isMissing = f.status === "missing_information" || !val;
    const badge = isMissing ? '<span style="color:#fbbf24; font-size:10px; float:right;">À compléter</span>' : '<span style="color:#10b981; font-size:10px; float:right;">Auto</span>';
    
    const card = document.createElement("div");
    card.className = "field-card";
    // Affichage des 50 premiers caractères du label trouvé
    const cleanLabel = f.label_detected.replace(/\s+/g, ' ').substring(0, 50);
    card.innerHTML = `<span class="field-label" title="${f.label_detected}">${cleanLabel}... ${badge}</span><input type="text" id="inp_${f.field_id}" value="${val.replace(/"/g, '&quot;')}" placeholder="Saisir la valeur..." />`;
    card.querySelector("input").addEventListener("input", (e) => valuesMap[f.field_id] = e.target.value);
    list.appendChild(card);
  });
}
EOF
echo "✅ Interface déverrouillée !"