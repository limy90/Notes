<script src="https://testingcf.jsdelivr.net/gh/zcoal/vpstest@main/vps-show-ping.js"></script>
<script>
(function () {
  window.DisableAnimatedMan = "true";
  window.ShowNetTransfer = "true";

  // 动态插入样式
  const style = document.createElement('style');
  style.textContent = `
/* 流量 ≥ 1 M/s 变红色 */
.nezha-traffic-high {
    color: #ff0000 !important;
    font-weight: 600;
}`;
  (document.head || document.documentElement).appendChild(style);

  // 流量高亮逻辑
  const THRESHOLD_MS = 1.0;

  function parseSpeed(text) {
    if (!text) return 0;
    text = text.trim();

    if (text.includes('M/s')) {
      return parseFloat(text);
    }
    if (text.includes('K/s')) {
      return parseFloat(text) / 1024;
    }
    return 0;
  }

  function highlight(node) {
    if (!node || !node.innerText) return;

    const text = node.innerText;
    if (!/(M\/s|K\/s)/.test(text)) return;

    const speed = parseSpeed(text);

    if (speed >= THRESHOLD_MS) {
      node.classList.add('nezha-traffic-high');
    } else {
      node.classList.remove('nezha-traffic-high');
    }
  }

  function scan(node) {
    if (!node) return;

    if (node.nodeType === Node.ELEMENT_NODE) {
      highlight(node);
    }

    node.querySelectorAll &&
      node.querySelectorAll('*').forEach(highlight);
  }

  const observer = new MutationObserver(mutations => {
    mutations.forEach(mutation => {
      mutation.addedNodes.forEach(scan);

      if (
        mutation.type === 'characterData' &&
        mutation.target.parentElement
      ) {
        highlight(mutation.target.parentElement);
      }
    });
  });

  observer.observe(document.body, {
    childList: true,
    subtree: true,
    characterData: true
  });

  scan(document.body);
})();
</script>
