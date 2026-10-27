#!/bin/bash
PROJECT_DIR="chrome-form-filler"
echo "🔧 Application du Patch 2 : Shadow DOM & Champs ATS..."

cat << 'EOF' > "$PROJECT_DIR/extension/content.js"
(() => {
  const fieldRegistry = new Map();
  const IGNORED_INPUT_TYPES = new Set(["hidden", "submit", "button", "reset", "image", "file", "checkbox", "radio"]);

  // Algorithme récursif pour percer les Shadow DOM (Web Components)
  function findElementsDeep(root) {
    let elements = [];
    const allNodes = root.querySelectorAll('*');
    for (const el of allNodes) {
      const tag = el.tagName.toLowerCase();
      if (tag === 'input' || tag === 'textarea' || tag === 'select') {
        elements.push(el);
      }
      if (el.shadowRoot) {
        elements = elements.concat(findElementsDeep(el.shadowRoot));
      }
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
    
    // 1. Chercher dans le document principal + Shadow DOMs
    let elements = findElementsDeep(document);
    
    // 2. Chercher dans les iframes de même origine (courant dans les ATS)
    const iframes = document.querySelectorAll('iframe');
    for (const iframe of iframes) {
      try {
        if (iframe.contentDocument) {
          elements = elements.concat(findElementsDeep(iframe.contentDocument));
        }
      } catch (e) {
        // Ignoré : iframe cross-origin bloqué par le navigateur
      }
    }

    const extractedFields = [];
    let counter = 0;

    elements.forEach((el) => {
      if (el.disabled || el.readOnly) return;
      const tag = el.tagName.toLowerCase();
      const inputType = (el.getAttribute("type") || (tag === "select" ? "select-one" : "text")).toLowerCase();
      
      // On ignore les types inutiles, MAIS on retire le filtre d'invisibilité (isVisible)
      // car les vrais <select> des ATS sont souvent cachés derrière l'interface graphique.
      if (tag === "input" && IGNORED_INPUT_TYPES.has(inputType)) return;

      const fieldId = `f_${counter++}`;
      fieldRegistry.set(fieldId, el);
      el.setAttribute("data-ai-field-id", fieldId);

      const label = extractLabel(el);
      const placeholder = el.getAttribute("placeholder") || "";
      const name = el.getAttribute("name") || "";
      
      let options = [];
      if (tag === "select") {
        options = Array.from(el.options)
          .filter(opt => opt.value !== "" && !opt.disabled)
          .map(opt => opt.text.trim() || opt.value.trim())
          .slice(0, 40);
      }

      extractedFields.push({
        field_id: fieldId, tag, input_type: inputType, name, dom_id: el.id || "",
        label, placeholder, surrounding_text: "", options, required: el.required || false,
        is_sensitive: inputType === "password"
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
    // "composed: true" permet à l'événement de traverser le Shadow DOM vers React/Angular
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
echo "✅ Fichier content.js mis à jour !"