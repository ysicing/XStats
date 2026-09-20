/* OpenStats 官网 · 页面外壳：主题切换、菜单栏下拉菜单与时钟 */
(() => {
  "use strict";

  const root = document.documentElement;
  const THEME_KEY = "os-theme";
  const media = window.matchMedia("(prefers-color-scheme: dark)");

  function saved() {
    try { return localStorage.getItem(THEME_KEY); } catch { return null; }
  }
  function applyTheme(theme, persist) {
    root.dataset.theme = theme;
    if (!persist) return;
    try { localStorage.setItem(THEME_KEY, theme); } catch { /* 隐私模式下不可用，忽略 */ }
  }

  applyTheme(saved() || (media.matches ? "dark" : "light"), false);
  // 没有手动选过时跟随系统
  media.addEventListener("change", (e) => { if (!saved()) applyTheme(e.matches ? "dark" : "light", false); });

  window.OpenStatsSite = {
    toggleTheme() { applyTheme(root.dataset.theme === "dark" ? "light" : "dark", true); },
  };
  document.getElementById("themeToggle")?.addEventListener("click", (e) => {
    e.stopPropagation();
    window.OpenStatsSite.toggleTheme();
  });

  // ── 菜单栏下拉菜单：点击展开，展开后悬停切换，点外部或 Esc 收起 ──
  const menus = [...document.querySelectorAll(".mb-menu")];
  let openMenu = null;

  function setMenu(menu) {
    for (const m of menus) {
      const open = m === menu;
      m.classList.toggle("is-open", open);
      m.querySelector(".mb-title")?.setAttribute("aria-expanded", String(open));
    }
    openMenu = menu;
  }

  for (const menu of menus) {
    const title = menu.querySelector(".mb-title");
    title?.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      setMenu(openMenu === menu ? null : menu);
    });
    menu.addEventListener("mouseenter", () => { if (openMenu && openMenu !== menu) setMenu(menu); });
    menu.querySelector(".mb-drop")?.addEventListener("click", () => setMenu(null));
  }
  document.addEventListener("click", (e) => { if (openMenu && !openMenu.contains(e.target)) setMenu(null); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") setMenu(null); });

  // ── 时钟：按访客本地时间显示 ──
  const clock = document.getElementById("menubarClock");
  const format = new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric", weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false });
  function renderClock() {
    if (!clock) return;
    const now = new Date();
    const parts = Object.fromEntries(format.formatToParts(now).map((p) => [p.type, p.value]));
    clock.textContent = `${parts.month}月${parts.day}日 ${parts.weekday} ${parts.hour}:${parts.minute}`;
    clock.dateTime = now.toISOString();
  }
  renderClock();
  setInterval(renderClock, 15000);
})();
