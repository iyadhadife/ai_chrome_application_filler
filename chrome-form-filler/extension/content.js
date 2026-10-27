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
