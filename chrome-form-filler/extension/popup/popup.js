const API_BASE = "http://localhost:8000";
document.getElementById("btn-scan").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const domResponse = await chrome.tabs.sendMessage(tab.id, { action: "SCAN_PAGE" });
  if(domResponse && domResponse.data) {
    document.getElementById("status-message").innerText = "Champs détectés : " + domResponse.data.fields.length;
  }
});
