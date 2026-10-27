(() => {
  const fieldRegistry = new Map();
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

  // NOUVELLE FONCTION ULTRA-AGRESSIVE POUR FORCER LE REMPLISSAGE
  function setNativeValue(element, value) {
    const tag = element.tagName.toLowerCase();
    
    // 1. Simuler le clic de l'utilisateur
    element.focus();
    element.click();

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
      // 2. Contourner les surcharges de React/Angular (Hack de l'objet natif)
      const prototype = tag === "textarea" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
      const valueSetter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
      
      // Assigner la valeur
      if (valueSetter) {
        valueSetter.call(element, value);
      } else {
        element.value = value;
      }
    }

    // 3. Déclencher toute la cascade d'événements qu'un humain produirait
    const events = ['keydown', 'keypress', 'input', 'keyup', 'change', 'blur'];
    events.forEach(eventType => {
      const event = new Event(eventType, { bubbles: true, composed: true, cancelable: true });
      element.dispatchEvent(event);
    });

    // 4. Feedback visuel (met le champ en surbrillance verte pour prouver qu'il a été touché)
    const originalBg = element.style.backgroundColor;
    element.style.backgroundColor = "#dcfce7";
    setTimeout(() => { element.style.backgroundColor = originalBg; }, 1500);
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
