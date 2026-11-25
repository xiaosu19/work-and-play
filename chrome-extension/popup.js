async function refresh() {
  const status = document.getElementById("status");
  try {
    const result = await chrome.runtime.sendMessage({ type: "status" });
    if (result?.connected && result.pageAvailable) {
      status.textContent = "已连接工时簿，可以识别当前网页。";
    } else if (result?.connected) {
      status.textContent = "已连接工时簿，当前网页还没有信号。请刷新此网页并检查扩展的网站访问权限。";
    } else {
      status.textContent = "未连接。请启动工时簿，并确认已安装本机连接器。";
    }
  } catch {
    status.textContent = "扩展连接中断。请重新加载扩展。";
  }
}
void refresh();
setInterval(refresh, 1000);
