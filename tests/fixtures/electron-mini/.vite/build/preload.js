contextBridge.exposeInMainWorld("codex", {
  read: () => ipcRenderer.invoke("workspace:read"),
  close: () => ipcRenderer.send("window:close"),
});
