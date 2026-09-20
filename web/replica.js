/* OpenStats 官网 · 应用界面还原
   菜单栏读数、详情弹窗、主窗口与刘海岛都是 HTML 重建，数据是本页随机游走生成的模拟值，
   不读取访客电脑的任何信息。风格、字号与布局对应应用内的 MenuBarRenderer、详情弹窗与主窗口。 */
(() => {
  "use strict";

  // ── 模拟数据 ──────────────────────────────────────────────
  const HISTORY = 30;
  const PROBES = 120;
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const walk = (v, step, lo, hi) => clamp(v + (Math.random() - 0.5) * step, lo, hi);
  const fill = (n, f) => Array.from({ length: n }, f);
  const ITEM_ORDER = ["cpu", "mem", "net", "gpu", "temp"];

  const S = {
    cpu: 0.24, cpuHistory: fill(HISTORY, () => 0.15 + Math.random() * 0.2),
    cores: fill(18, (_, i) => (i < 6 ? 0.1 : 0.35) + Math.random() * 0.2),
    gpu: 0.12, gpuHistory: fill(HISTORY, () => Math.random() * 0.25),
    mem: 0.68, memHistory: fill(HISTORY, () => 0.68),
    up: 12 * 1024, down: 1.4 * 1024 * 1024,
    upHistory: fill(HISTORY, () => Math.random() * 40 * 1024),
    downHistory: fill(HISTORY, () => Math.random() * 1.6 * 1024 * 1024),
    probes: fill(36, () => 58 + Math.random() * 12),
    cpuTemp: 52, gpuTemp: 47, memTemp: 45, batteryTemp: 31, palmTemp: 30,
    fans: [1640, 1760], fanMode: "auto",
    keepAwake: false, awakeMode: "display", lidClosed: false, duration: 0,
    items: readList("os-items", ["cpu", "mem", "net"]),
    popover: null,
    page: "overview", windowOpen: false, sort: "cpu",
    dns: "auto", dnsManual: false, dnsNote: "",
    style: read("os-style", "stacked"),
    cleaned: false, cleaning: false, confirming: false,
  };

  const FAN_RANGE = [[1350, 5349], [1350, 5777]];
  const PROCESSES = [
    ["Safari", 1], ["Xcode", 1], ["WindowServer", 3], ["音乐", 4], ["访达", 1], ["OpenStats", 1],
    ["终端", 3], ["照片", 5], ["备忘录", 5], ["邮件", 2], ["Spotlight", 6], ["系统设置", 6],
  ].map(([name, color]) => ({ name, color, cpu: Math.random() * 0.3, mem: (80 + Math.random() * 900) * 1024 * 1024 }));
  const NET_PROCESSES = [["Safari", 1], ["音乐", 4], ["邮件", 2], ["终端", 3], ["照片", 5]]
    .map(([name, color]) => ({ name, color, down: Math.random() * 400 * 1024, up: Math.random() * 60 * 1024 }));

  const CLEAN_RULES = [
    { id: "caches", cat: "系统", title: "应用缓存", detail: "10 项 · 8 项使用中", size: 3.5e9, on: true },
    { id: "logs", cat: "系统", title: "应用日志与崩溃报告", detail: "10 项", size: 1.9e6, on: true },
    { id: "chrome", cat: "浏览器", title: "Chrome 缓存", detail: "Chrome 正在运行", size: 0, blocked: true },
    { id: "safari", cat: "浏览器", title: "Safari 缓存", detail: "1 项", size: 812e6, on: true },
    { id: "derived", cat: "开发者", title: "Xcode 编译缓存", detail: "6 项", size: 6.2e9, on: true },
    { id: "npm", cat: "开发者", title: "npm 缓存", detail: "1 项", size: 11.8e9, on: true },
    { id: "installers", cat: "下载", title: "安装包", detail: "3 项 · 移到废纸篓", size: 1.2e9, on: false },
    { id: "trash", cat: "废纸篓", title: "清空废纸篓", detail: "永久删除", size: 640e6, on: false },
  ];

  const DNS_PRESETS = [
    ["auto", "自动", []], ["cloudflare", "Cloudflare", ["1.1.1.1", "1.0.0.1"]], ["google", "Google", ["8.8.8.8", "8.8.4.4"]],
    ["tencent", "腾讯 DNSPod", ["119.29.29.29", "182.254.116.116"], "腾讯"], ["aliyun", "阿里云", ["223.5.5.5", "223.6.6.6"]],
  ];

  function read(key, fallback) {
    try { return localStorage.getItem(key) || fallback; } catch { return fallback; }
  }
  function readList(key, fallback) {
    const value = read(key, "");
    const list = value.split(",").filter((k) => ITEM_ORDER.includes(k));
    return value ? list : fallback;
  }
  function write(key, value) {
    try { localStorage.setItem(key, value); } catch { /* 隐私模式下不可用，忽略 */ }
  }

  function push(history, value, size = HISTORY) {
    history.push(value);
    if (history.length > size) history.shift();
  }

  function tick() {
    S.cores = S.cores.map((v, i) => walk(v, 0.18, 0.02, i < 6 ? 0.55 : 0.9));
    S.cpu = S.cores.reduce((a, b) => a + b, 0) / S.cores.length;
    S.gpu = walk(S.gpu, 0.12, 0, 0.6);
    S.mem = walk(S.mem, 0.01, 0.6, 0.78);
    S.up = clamp(S.up * (0.6 + Math.random() * 0.8) + Math.random() * 8000, 800, 4 * 1024 * 1024);
    S.down = clamp(S.down * (0.6 + Math.random() * 0.8) + Math.random() * 60000, 2000, 60 * 1024 * 1024);
    S.cpuTemp = walk(S.cpuTemp, 2, 42, 78);
    S.gpuTemp = walk(S.gpuTemp, 1.5, 40, 70);
    push(S.cpuHistory, S.cpu); push(S.gpuHistory, S.gpu); push(S.memHistory, S.mem);
    push(S.upHistory, S.up); push(S.downHistory, S.down);
    // 探测：偶尔一次偏慢或超时
    const roll = Math.random();
    push(S.probes, roll < 0.02 ? null : roll < 0.06 ? 220 + Math.random() * 80 : 58 + Math.random() * 12, PROBES);

    const targets = { auto: [0.07 + S.cpu * 0.3, 0.08 + S.cpu * 0.3], cool: [0.6, 0.6], max: [1, 1], custom: [0.45, 0.45] }[S.fanMode];
    S.fans = S.fans.map((rpm, i) => {
      const [lo, hi] = FAN_RANGE[i];
      const target = lo + (hi - lo) * targets[i];
      return Math.round(rpm + (target - rpm) * 0.35);
    });
    PROCESSES.forEach((p) => { p.cpu = clamp(p.cpu + (Math.random() - 0.5) * 0.2, 0, 1.2); });
    NET_PROCESSES.forEach((p) => {
      p.down = clamp(p.down * (0.5 + Math.random()), 0, 8 * 1024 * 1024);
      p.up = clamp(p.up * (0.5 + Math.random()), 0, 1024 * 1024);
    });
  }

  // ── 格式化 ────────────────────────────────────────────────
  const pct = (v) => `${Math.round(clamp(v, 0, 1) * 100)}%`;
  function rate(bps) {
    const units = ["B/s", "KB/s", "MB/s", "GB/s"];
    let value = Math.max(0, bps), i = 0;
    while (value >= 999.5 && i < units.length - 1) { value /= 1024; i++; }
    const text = i >= 2 && value < 9.95 ? value.toFixed(1) : String(Math.round(value));
    return `${text} ${units[i]}`;
  }
  function bytes(n, decimal = true) {
    const step = decimal ? 1000 : 1024;
    const units = ["B", "KB", "MB", "GB", "TB"];
    let value = n, i = 0;
    while (value >= step && i < units.length - 1) { value /= step; i++; }
    return i === 0 ? `${Math.round(value)} B` : `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[i]}`;
  }
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const splitRate = (bps) => { const [n, u] = rate(bps).split(" "); return `${n}<small>${u}</small>`; };

  // ── SVG 图形 ──────────────────────────────────────────────
  function barsSVG(values, { w = 190, h = 40, count = 20, cls = "fill-primary" } = {}) {
    const recent = values.slice(-count);
    const gap = 2, bw = (w - gap * (count - 1)) / count;
    let out = "";
    for (let i = 0; i < count; i++) {
      const v = recent[i - (count - recent.length)];
      const x = i * (bw + gap);
      if (v === undefined) { out += `<rect class="fill-track" x="${x}" y="${h - 2}" width="${bw}" height="2"/>`; continue; }
      const bh = Math.max(2, h * clamp(v, 0, 1));
      out += `<rect class="${v >= 0.8 ? "fill-warning" : cls}" x="${x}" y="${h - bh}" width="${bw}" height="${bh}" rx="1"/>`;
    }
    return `<svg class="op-chart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">${out}</svg>`;
  }

  function points(values, w, top, span, max, invert = false) {
    const step = w / (HISTORY - 1);
    return values.map((v, i) => {
      const x = w - (values.length - 1 - i) * step;
      const offset = span * clamp(v / max, 0, 1);
      return [x, invert ? top + offset : top + span - offset];
    });
  }
  const pathOf = (pts) => pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join("");

  function lineSVG(values, { w = 190, h = 40, max = 1, cls = "primary" } = {}) {
    const d = pathOf(points(values, w, 1, h - 2, max));
    return `<svg class="op-chart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
      <path class="area-${cls}" d="${d}L${w},${h}L0,${h}Z"/><path class="stroke-${cls}" d="${d}"/></svg>`;
  }
  function dualSVG(up, down, { w = 190, h = 40 } = {}) {
    const max = Math.max(...up, ...down, 64 * 1024) * 1.1;
    const du = pathOf(points(up, w, 1, h - 2, max)), dd = pathOf(points(down, w, 1, h - 2, max));
    return `<svg class="op-chart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
      <path class="area-down" d="${dd}L${w},${h}L0,${h}Z"/><path class="stroke-down" d="${dd}"/>
      <path class="area-up" d="${du}L${w},${h}L0,${h}Z"/><path class="stroke-up" d="${du}"/></svg>`;
  }
  /** 上下镜像：上半上传、下半下载，各自按峰值缩放 */
  function mirroredSVG(up, down, { w = 296, h = 72 } = {}) {
    const mid = h / 2;
    const du = pathOf(points(up, w, 1, mid - 1, Math.max(...up, 64 * 1024)));
    const dd = pathOf(points(down, w, mid, mid - 1, Math.max(...down, 64 * 1024), true));
    const first = w - (up.length - 1) * (w / (HISTORY - 1));
    return `<svg class="op-chart op-chart--tall" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
      <path class="area-up" d="${du}L${w},${mid}L${first},${mid}Z"/><path class="stroke-up" d="${du}"/>
      <path class="area-down" d="${dd}L${w},${mid}L${first},${mid}Z"/><path class="stroke-down" d="${dd}"/>
      <rect class="fill-track" x="0" y="${mid - 0.5}" width="${w}" height="1"/></svg>`;
  }
  function ringSVG(fraction, size, width, cls) {
    const r = (size - width) / 2, c = 2 * Math.PI * r;
    return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
      <circle class="ring-track" cx="${size / 2}" cy="${size / 2}" r="${r}" stroke-width="${width}" fill="none"/>
      <circle class="${cls}" cx="${size / 2}" cy="${size / 2}" r="${r}" stroke-width="${width}" fill="none" stroke-linecap="round"
        stroke-dasharray="${(c * clamp(fraction, 0, 1)).toFixed(2)} ${c.toFixed(2)}" transform="rotate(-90 ${size / 2} ${size / 2})"/></svg>`;
  }

  // ── 图标（线性 SVG，不使用 emoji） ──────────────────────────
  const ICON = {
    cpu: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="4" y="4" width="8" height="8" rx="1.5"/><path d="M6 1.5v2.5M10 1.5v2.5M6 12v2.5M10 12v2.5M1.5 6H4M1.5 10H4M12 6h2.5M12 10h2.5"/></svg>',
    mem: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="1.5" y="4" width="13" height="6.5" rx="1.2"/><path d="M4.5 10.5v2.5M8 10.5v2.5M11.5 10.5v2.5"/></svg>',
    net: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M5 13V3M2.5 5.5 5 3l2.5 2.5M11 3v10M8.5 10.5 11 13l2.5-2.5"/></svg>',
    gpu: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M8 1.8 14.2 5 8 8.2 1.8 5z"/><path d="M1.8 8 8 11.2 14.2 8M1.8 11 8 14.2l6.2-3.2"/></svg>',
    temp: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M6.5 9.3V3a1.5 1.5 0 0 1 3 0v6.3a3 3 0 1 1-3 0z"/><circle cx="8" cy="11.8" r="1" fill="currentColor"/></svg>',
    dash: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/><rect x="2" y="9" width="5" height="5" rx="1"/><rect x="9" y="9" width="5" height="5" rx="1"/></svg>',
    list: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5"/><path d="M4.5 6h7M4.5 8.5h7M4.5 11h4"/></svg>',
    cup: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M2.5 6h9v3.5a3.5 3.5 0 0 1-3.5 3.5H6A3.5 3.5 0 0 1 2.5 9.5z"/><path d="M11.5 7h1a1.5 1.5 0 0 1 0 3h-1M5 1.8v2M8 1.8v2"/></svg>',
    laptop: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="3" y="3.5" width="10" height="7" rx="1"/><path d="M1.5 12.5h13" stroke-linecap="round"/></svg>',
    fan: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="1.5"/><path d="M8 6.5C8 3 9.5 1.8 11 2.6s1 3.4-3 3.9M9.5 8c3.5 0 4.7 1.5 3.9 3s-3.4 1-3.9-3M8 9.5c0 3.5-1.5 4.7-3 3.9s-1-3.4 3-3.9M6.5 8C3 8 1.8 6.5 2.6 5s3.4-1 3.9 3"/></svg>',
    clean: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M8 1.5 9.3 6.7 14.5 8 9.3 9.3 8 14.5 6.7 9.3 1.5 8l5.2-1.3z"/></svg>',
    window: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M1.5 5.5h13"/></svg>',
    gear: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="2.3"/><path d="M8 1.5v2M8 12.5v2M14.5 8h-2M3.5 8h-2M12.6 3.4l-1.4 1.4M4.8 11.2l-1.4 1.4M12.6 12.6l-1.4-1.4M4.8 4.8 3.4 3.4"/></svg>',
    moon: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M13.5 9.8A6 6 0 1 1 6.2 2.5a4.8 4.8 0 0 0 7.3 7.3z"/></svg>',
    power: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M8 1.8v5.4M4.4 3.8a5.4 5.4 0 1 0 7.2 0"/></svg>',
    refresh: '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M12 7a5 5 0 1 1-1.5-3.6M12 1.5v2.5H9.5"/></svg>',
    warn: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M8 2 14.5 13.5h-13z"/><path d="M8 6.5v3M8 11.5v.1" stroke-linecap="round"/></svg>',
    check: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m3.5 8.5 3 3 6-7"/></svg>',
    apple: '<svg width="9" height="11" viewBox="0 0 14 17" fill="currentColor" aria-hidden="true"><path d="M11.5 9c0-1.9 1.5-2.8 1.6-2.9-.9-1.3-2.2-1.5-2.7-1.5-1.1-.1-2.2.7-2.8.7-.6 0-1.5-.7-2.4-.6-1.2 0-2.4.7-3 1.8-1.3 2.2-.3 5.4 1 7.2.6.8 1.3 1.8 2.2 1.7.9 0 1.2-.6 2.2-.6 1 0 1.3.6 2.2.5.9 0 1.5-.8 2.1-1.7.7-1 .9-1.9.9-1.9s-1.8-.7-1.8-2.7zM9.7 3.2c.5-.6.8-1.4.7-2.2-.7 0-1.6.5-2.1 1.1-.5.6-.9 1.4-.8 2.2.8.1 1.7-.4 2.2-1.1z"/></svg>',
  };

  // ── 菜单栏读数：八种风格 ────────────────────────────────────
  const STYLES = [
    ["stacked", "双行文字", "小标签在上、数值在下，最紧凑"],
    ["inline", "单行文字", "标签与数值同一行，最易读"],
    ["icon", "图标", "用系统图标代替文字标签"],
    ["ring", "圆环", "圆环表示当前占用比例"],
    ["pie", "饼图", "饼图表示当前占用比例"],
    ["history", "柱状历史", "10 根柱子是最近 10 次采样（约 20 秒）的变化"],
    ["meter", "电量条", "竖向电量条表示当前占用比例"],
    ["dot", "状态圆点", "绿色正常、橙色偏高（60% 以上）、红色很高（85% 以上）"],
  ];
  const MINI = {
    cpu: '<svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1"><rect x="2.5" y="2.5" width="6" height="6" rx="1"/><path d="M4 .5v2M7 .5v2M4 8.5v2M7 8.5v2M.5 4h2M.5 7h2M8.5 4h2M8.5 7h2"/></svg>',
    mem: '<svg width="13" height="9" viewBox="0 0 13 9" fill="none" stroke="currentColor" stroke-width="1"><rect x=".5" y="1.5" width="12" height="5" rx="1"/><path d="M3 6.5v2M6.5 6.5v2M10 6.5v2"/></svg>',
    gpu: '<svg width="12" height="11" viewBox="0 0 12 11" fill="none" stroke="currentColor" stroke-width="1"><path d="M6 .8 11.2 3.4 6 6 .8 3.4z"/><path d="M.8 5.6 6 8.2l5.2-2.6M.8 7.8 6 10.4l5.2-2.6"/></svg>',
    temp: '<svg width="7" height="12" viewBox="0 0 7 12" fill="none" stroke="currentColor" stroke-width="1"><path d="M2 7V1.8a1.5 1.5 0 0 1 3 0V7a2.6 2.6 0 1 1-3 0z"/></svg>',
  };

  function shape(style, value, history) {
    const f = clamp(value, 0, 1);
    switch (style) {
      case "ring": {
        const r = 5.5, c = 2 * Math.PI * r;
        return `<svg width="13" height="13" viewBox="0 0 13 13"><circle cx="6.5" cy="6.5" r="${r}" fill="none" stroke="currentColor" stroke-opacity=".25" stroke-width="2"/><circle cx="6.5" cy="6.5" r="${r}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-dasharray="${(c * f).toFixed(2)} ${c.toFixed(2)}" transform="rotate(-90 6.5 6.5)"/></svg>`;
      }
      case "pie": {
        const a = f * 2 * Math.PI, x = 6.5 + 6.5 * Math.sin(a), y = 6.5 - 6.5 * Math.cos(a);
        const wedge = f >= 0.999 ? '<circle cx="6.5" cy="6.5" r="6.5" fill="currentColor"/>'
          : `<path d="M6.5 6.5V0A6.5 6.5 0 ${f > 0.5 ? 1 : 0} 1 ${x.toFixed(2)} ${y.toFixed(2)}Z" fill="currentColor"/>`;
        return `<svg width="13" height="13" viewBox="0 0 13 13"><circle cx="6.5" cy="6.5" r="6.5" fill="currentColor" fill-opacity=".25"/>${wedge}</svg>`;
      }
      case "history": {
        const recent = history.slice(-10);
        const bars = recent.map((v, i) => { const h = Math.max(1, 13 * clamp(v, 0, 1)); return `<rect x="${i * 3}" y="${13 - h}" width="2" height="${h}" fill="currentColor"/>`; }).join("");
        return `<svg width="29" height="13" viewBox="0 0 29 13"><rect x="0" y="12" width="29" height="1" fill="currentColor" fill-opacity=".25"/>${bars}</svg>`;
      }
      case "meter": {
        const h = Math.max(3.4, 13 * f);
        return `<svg width="5" height="13" viewBox="0 0 5 13"><rect width="5" height="13" rx="1.7" fill="currentColor" fill-opacity=".25"/><rect y="${13 - h}" width="5" height="${h}" rx="1.7" fill="currentColor"/></svg>`;
      }
      case "dot": {
        const cls = f >= 0.85 ? "fill-error" : f >= 0.6 ? "fill-warning" : "fill-success";
        return `<svg width="5" height="5" viewBox="0 0 5 5"><circle class="${cls}" cx="2.5" cy="2.5" r="2.5"/></svg>`;
      }
      default: return "";
    }
  }

  function metricHTML(key, label, value, history, style, text = pct(value)) {
    const stacked = `<span class="mbs__stack"><span class="mbs__label">${label}</span><span class="mbs__value">${text}</span></span>`;
    if (style === "stacked") return `<span class="mbs">${stacked}</span>`;
    if (style === "inline") return `<span class="mbs"><span class="mbs__inline-label">${label}</span><span class="mbs__inline-value">${text}</span></span>`;
    if (style === "icon") return `<span class="mbs">${MINI[key]}<span class="mbs__inline-value">${text}</span></span>`;
    if (key === "temp") return `<span class="mbs">${stacked}</span>`;
    return `<span class="mbs">${shape(style, value, history)}${stacked}</span>`;
  }

  function itemHTML(key, style) {
    switch (key) {
      case "cpu": return metricHTML("cpu", "CPU", S.cpu, S.cpuHistory, style);
      case "mem": return metricHTML("mem", "RAM", S.mem, S.memHistory, style);
      case "gpu": return metricHTML("gpu", "GPU", S.gpu, S.gpuHistory, style);
      case "temp": return metricHTML("temp", "TEMP", 0, [], style, `${Math.round(S.cpuTemp)}°`);
      case "net": return `<span class="mbs"><span class="mbs__net"><span><i class="up"></i>${rate(S.up)}</span><span><i class="down"></i>${rate(S.down)}</span></span></span>`;
      default: return "";
    }
  }

  // ── 共用片段 ──────────────────────────────────────────────
  const card = (head, body, extra = "") => `<div class="op-card ${extra}"><div class="op-card__head">${head}</div>${body}</div>`;
  const row = (label, value) => `<div class="op-info"><span>${label}</span><b>${value}</b></div>`;
  const copyable = (text) => `<button class="op-copy" type="button" data-copy="${esc(text)}" title="点击拷贝">${esc(text)}</button>`;
  const tempTone = (t) => (t >= 80 ? "op-chip--warning" : "op-chip--primary");
  const level = (v) => (v < 0.3 ? "低负载" : v < 0.7 ? "中等负载" : "高负载");
  const loadRing = (v) => (v >= 0.85 ? "ring-error" : v >= 0.6 ? "ring-warning" : "ring-primary");

  function procRows(list, cols) {
    return `<div class="op-procs">${list.map((p) => `<div class="op-proc op-proc--${cols.length}"><i class="op-proc__icon proc-c${p.color}"></i><span class="op-proc__name">${esc(p.name)}</span>${cols.map((c) => `<span class="op-proc__num">${c(p)}</span>`).join("")}</div>`).join("")}</div>`;
  }
  const cpuText = (p) => `${(p.cpu * 100).toFixed(1)}%`;
  const memText = (p) => bytes(p.mem, false);

  // ── 各指标内容（弹窗与主窗口共用，wide 为主窗口） ─────────────
  const CONTENT = {
    cpu(wide) {
      const cores = S.cores.slice(12).concat(S.cores.slice(0, 12));
      const coreBars = cores.map((v, i) => `${i === 6 ? '<i class="gap"></i>' : ""}<i><b style="height:${Math.round(v * 100)}%"></b></i>`).join("");
      const hero = `<div class="op-card"><div class="op-hero">${ringSVG(S.cpu, 56, 6, loadRing(S.cpu))}<span class="op-hero__ring">${pct(S.cpu)}</span>
        <div class="op-hero__legend"><span class="op-legend"><i class="bg-primary"></i>用户 <b>${Math.round(S.cpu * 72)}%</b></span><span class="op-legend"><i class="bg-secondary"></i>系统 <b>${Math.round(S.cpu * 28)}%</b></span><span class="op-legend"><i class="bg-track"></i>空闲 <b>${pct(1 - S.cpu)}</b></span></div>
        <span class="op-chip ${tempTone(S.cpuTemp)}">${Math.round(S.cpuTemp)}°C</span></div></div>`;
      const history = card(`负载历史 <span class="op-card__note">最近 60 秒</span>`, barsSVG(S.cpuHistory, { count: wide ? 30 : 24, w: wide ? 600 : 296, h: wide ? 96 : 48 }));
      const coresCard = card("核心负载", `<div class="op-cores">${coreBars}</div><div class="op-core-labels"><span>超级核 · 6</span><span>性能核 · 12</span></div>`);
      const info = card("处理器信息", row("处理器", "Apple M5 Max") + row("核心", "18 核（6 超级核 + 12 性能核）") + row("负载平均", `${(S.cpu * 18).toFixed(2)} · ${(S.cpu * 16).toFixed(2)} · ${(S.cpu * 15).toFixed(2)}`) + row("已运行", "3 天 4 小时"));
      const procs = card(`高占用进程 <span class="op-card__note">CPU</span>`, procRows([...PROCESSES].sort((a, b) => b.cpu - a.cpu).slice(0, 5), [cpuText]));
      return wide ? `${hero}${history}<div class="op-row op-row--2">${coresCard}${info}</div>${procs}` : hero + history + coresCard + info + procs;
    },

    mem(wide) {
      const used = S.mem * 64;
      const hero = `<div class="op-card"><div class="op-hero">${ringSVG(S.mem, 56, 6, "ring-success")}<span class="op-hero__ring">${pct(S.mem)}</span>
        <div class="op-hero__legend"><span class="op-value">${used.toFixed(1)} GB<small>/ 64.0 GB</small></span><span class="op-badge op-badge--success">内存压力 正常</span></div></div></div>`;
      const history = card(`使用历史 <span class="op-card__note">最近 60 秒</span>`, lineSVG(S.memHistory, { w: wide ? 600 : 296, h: wide ? 96 : 48 }));
      const app = used * 0.78, wired = used * 0.14, comp = used * 0.08;
      const parts = [["bg-primary", "App 内存", app], ["bg-secondary", "联动内存", wired], ["bg-warning", "被压缩", comp], ["bg-muted", "缓存文件", 19.2], ["bg-track", "交换空间", 0.01]];
      const stack = `<div class="op-stack"><i class="bg-primary" style="width:${(app / 64 * 100).toFixed(1)}%"></i><i class="bg-secondary" style="width:${(wired / 64 * 100).toFixed(1)}%"></i><i class="bg-warning" style="width:${(comp / 64 * 100).toFixed(1)}%"></i></div>`;
      const breakdown = card("内存构成", stack + parts.map(([cls, t, gb]) => `<div class="op-info"><span><i class="op-swatch ${cls}"></i>${t}</span><b>${gb < 1 ? "12.8 MB" : `${gb.toFixed(1)} GB`}</b></div>`).join("")
        + `<button class="op-btn" type="button" data-action="purge">释放内存</button>`);
      const procs = card(`高占用进程 <span class="op-card__note">内存</span>`, procRows([...PROCESSES].sort((a, b) => b.mem - a.mem).slice(0, 5), [memText]));
      return wide ? `${hero}${history}<div class="op-row op-row--2">${breakdown}${procs}</div>` : hero + history + breakdown + procs;
    },

    net(wide) {
      const hero = `<div class="op-card"><div class="op-rates">
        <div><div class="op-value">${splitRate(S.down)}</div><span class="op-legend"><i class="bg-down"></i>下载</span></div>
        <div><div class="op-value">${splitRate(S.up)}</div><span class="op-legend"><i class="bg-up"></i>上传</span></div></div></div>`;
      const history = card(`流量历史 <span class="op-card__note">最近 60 秒</span>`,
        `<div class="op-mirror"><span>峰值 ↑ ${rate(Math.max(...S.upHistory, 64 * 1024))}</span>${mirroredSVG(S.upHistory, S.downHistory, { w: wide ? 600 : 296, h: wide ? 120 : 72 })}<span>峰值 ↓ ${rate(Math.max(...S.downHistory, 64 * 1024))}</span></div>`);

      const count = wide ? 120 : 60;
      const recent = S.probes.slice(-count);
      const cells = fill(count - recent.length, () => '<i></i>').join("")
        + recent.map((v) => `<i class="${v == null ? "is-fail" : v >= 200 ? "is-slow" : "is-ok"}"></i>`).join("");
      const ok = recent.filter((v) => v != null);
      const jitter = ok.slice(-20).reduce((a, v, i, arr) => (i ? a + Math.abs(v - arr[i - 1]) : a), 0) / Math.max(1, Math.min(ok.length, 20) - 1);
      const loss = recent.length ? recent.filter((v) => v == null).length / recent.length : 0;
      const last = [...recent].reverse().find((v) => v != null);
      const probe = card(`连接探测 <span class="op-card__note">1.1.1.1 · 每 2 秒</span>`,
        `<div class="op-probe ${wide ? "op-probe--wide" : ""}">${cells}</div>
        <div class="op-stats"><div><small>延迟</small><b>${last ? Math.round(last) : "—"} ms</b></div><div><small>抖动</small><b>${jitter.toFixed(1)} ms</b></div><div><small>丢包</small><b>${Math.round(loss * 100)}%</b></div></div>`);

      const iface = card("接口", row("接口", "Wi‑Fi（en0）") + row("状态", '<span class="op-badge op-badge--success">已连接</span>')
        + row("物理地址", copyable("a4:83:e7:12:34:56")) + row("信号强度", "-42 dBm · 极好") + row("传输速率", "1200 Mbps")
        + row("开机后下载", "18.4 GB") + row("开机后上传", "2.1 GB"));
      const addresses = card(`IP 地址 <button class="op-mini" type="button" data-action="lookup" aria-label="重新查询公网 IP">${ICON.refresh}</button>`,
        row("本地 IPv4", copyable("192.168.1.20")) + row("本地 IPv6", copyable("2001:db8::20")) + row("路由器", copyable("192.168.1.1"))
        + row("公网 IPv4", copyable("203.0.113.24")) + row("公网 IPv6", copyable("2001:db8:85a3::8a2e"))
        + row("归属地", '<span class="op-flag"><img src="assets/flags/cn.svg" alt="" width="16" height="12">中国 · Shanghai</span>')
        + row("ASN", copyable("AS64500")) + row("网络运营方", "EXAMPLE NETWORK"));

      const current = DNS_PRESETS.find(([id]) => id === S.dns);
      const servers = S.dns === "auto" ? "192.168.1.1" : current[2].join("<br>");
      const chips = DNS_PRESETS.map(([id, title, , short]) => `<button class="op-chipbtn" type="button" data-dns="${id}" aria-pressed="${!S.dnsManual && S.dns === id}" title="${title}">${short || title}</button>`).join("")
        + `<button class="op-chipbtn" type="button" data-action="dns-manual" aria-pressed="${S.dnsManual}">手动</button>`;
      const manual = S.dnsManual ? `<form class="op-field" data-form="dns"><input name="servers" type="text" placeholder="例如 1.1.1.1, 8.8.8.8" aria-label="DNS 服务器" autocomplete="off"><button class="op-btn op-btn--primary" type="submit">应用</button></form>` : "";
      const dns = card(`DNS <span class="op-card__note">Wi‑Fi</span>`,
        row("正在使用", servers) + row("配置方式", S.dns === "auto" ? "自动（由路由器分配）" : current[1])
        + `<div class="op-chipgrid">${chips}</div>${manual}
        <div class="op-actions"><button class="op-btn" type="button" data-action="flush">刷新 DNS 缓存</button></div>
        ${S.dnsNote ? `<div class="op-note">${esc(S.dnsNote)}</div>` : ""}`);

      const procs = card(`高占用进程 <span class="op-card__note">下载 · 上传</span>`,
        procRows([...NET_PROCESSES].sort((a, b) => b.down + b.up - a.down - a.up), [(p) => rate(p.down), (p) => rate(p.up)]));
      return wide
        ? `${hero}<div class="op-row op-row--2">${history}${probe}</div><div class="op-row op-row--2">${iface}${addresses}</div><div class="op-row op-row--2">${dns}${procs}</div>`
        : hero + history + probe + iface + addresses + dns + procs;
    },

    gpu(wide) {
      const hero = `<div class="op-card"><div class="op-hero">${ringSVG(S.gpu, 56, 6, loadRing(S.gpu))}<span class="op-hero__ring">${pct(S.gpu)}</span>
        <div class="op-hero__legend"><b>Apple M5 Max</b><span class="op-foot">40 核图形处理器</span></div>
        <span class="op-chip ${tempTone(S.gpuTemp)}">${Math.round(S.gpuTemp)}°C</span></div></div>`;
      return hero + card(`使用历史 <span class="op-card__note">最近 60 秒</span>`, lineSVG(S.gpuHistory, { cls: "secondary", w: wide ? 600 : 296, h: wide ? 96 : 48 }))
        + card("显卡信息", row("型号", "Apple M5 Max") + row("核心数", "40") + row("最高温度", `${Math.round(S.gpuTemp)}°C`));
    },

    temp(wide) {
      if (wide) return thermalPage();
      const temps = [["CPU", S.cpuTemp], ["GPU", S.gpuTemp], ["内存", S.memTemp], ["电池", S.batteryTemp], ["掌托", S.palmTemp]]
        .map(([t, v]) => `<div class="op-info"><span>${t}</span><b>${Math.round(v)}°C</b></div><div class="op-track op-track--thin"><i class="${v >= 80 ? "bg-warning" : ""}" style="width:${Math.round(v / 110 * 100)}%"></i></div>`).join("");
      const fans = S.fans.map((rpm, i) => `<div class="op-info"><span>风扇 ${i + 1}</span><b>${rpm.toLocaleString("en-US")} RPM</b></div><div class="op-track op-track--thin"><i style="width:${Math.round(rpm / FAN_RANGE[i][1] * 100)}%"></i></div>`).join("");
      const modes = [["auto", "自动"], ["cool", "降温"], ["max", "强冷"]].map(([m, t]) => `<button class="op-chipbtn" type="button" data-fan="${m}" aria-pressed="${S.fanMode === m}">${t}</button>`).join("");
      return `<div class="op-card"><div class="op-rates"><div><small class="op-foot">CPU 最高</small><div class="op-value">${Math.round(S.cpuTemp)}°C</div></div><div><small class="op-foot">风扇</small><div class="op-value">${Math.max(...S.fans).toLocaleString("en-US")}<small>RPM</small></div></div></div></div>`
        + card(`温度 <span class="op-card__note">最高</span>`, temps)
        + card(`风扇 <span class="op-card__note">${S.fanMode === "auto" ? "由 macOS 调节" : "OpenStats 控制中"}</span>`, `${fans}<div class="op-chipgrid op-chipgrid--3">${modes}</div>`);
    },
  };

  const ITEM_META = {
    cpu: ["CPU", ICON.cpu], mem: ["内存", ICON.mem], net: ["网络", ICON.net], gpu: ["GPU", ICON.gpu], temp: ["温度", ICON.temp],
  };

  // ── 菜单栏与详情弹窗 ───────────────────────────────────────
  const itemsBox = document.getElementById("mbItems");
  const popover = document.getElementById("osPopover");

  /** 按钮保持不变，只替换里面的读数：刷新时整个按钮被替换会让恰好落在刷新瞬间的点击丢失 */
  function renderMenubar() {
    if (!itemsBox) return;
    const items = ITEM_ORDER.filter((k) => S.items.includes(k));
    const keys = items.length ? items : ["window"];
    const current = [...itemsBox.children].map((b) => b.dataset.item || "window");
    if (current.join() !== keys.join()) {
      itemsBox.innerHTML = keys.map((key) => key === "window"
        ? `<button class="mb-stats" type="button" data-action="window" aria-label="打开 OpenStats"></button>`
        : `<button class="mb-stats" type="button" data-item="${key}" aria-label="${ITEM_META[key][0]}详情" aria-haspopup="dialog"></button>`).join("");
    }
    [...itemsBox.children].forEach((button, index) => {
      const key = keys[index];
      if (key === "window") { button.innerHTML = ICON.dash; return; }
      const awake = index === 0 && S.keepAwake ? `<span class="mbs" title="防休眠已开启">${ICON.cup}</span>` : "";
      button.innerHTML = awake + itemHTML(key, S.style);
      button.setAttribute("aria-expanded", String(S.popover === key));
    });
  }

  function renderPopover() {
    if (!S.popover) { popover.hidden = true; return; }
    const [title, icon] = ITEM_META[S.popover];
    const previous = popover.querySelector(".op-popbody");
    const scroll = previous && previous.dataset.item === S.popover ? previous.scrollTop : 0;
    popover.innerHTML = `<div class="op-pophead">${icon}<b>${title}</b>
        <button class="op-icon" type="button" data-action="window" aria-label="打开 OpenStats 主窗口">${ICON.window}</button>
        <button class="op-icon" type="button" data-action="settings" aria-label="设置">${ICON.gear}</button></div>
      <div class="op-popbody" data-item="${S.popover}">${CONTENT[S.popover](false)}</div>`;
    popover.hidden = false;
    popover.querySelector(".op-popbody").scrollTop = scroll;
    placePopover();
  }

  function placePopover() {
    const anchor = itemsBox.querySelector(`[data-item="${S.popover}"]`);
    if (!anchor) return;
    const margin = 8;
    const width = Math.min(320, window.innerWidth - margin * 2);
    const rect = anchor.getBoundingClientRect();
    const left = clamp(rect.left + rect.width / 2 - width / 2, margin, window.innerWidth - width - margin);
    popover.style.left = `${left}px`;
    popover.style.width = `${width}px`;
  }

  function openPopover(key) {
    S.popover = S.popover === key ? null : key;
    renderMenubar();
    renderPopover();
  }
  function closePopover() {
    if (!S.popover) return;
    S.popover = null;
    renderMenubar();
    renderPopover();
  }

  // ── 主窗口 ────────────────────────────────────────────────
  const appWindow = document.getElementById("osWindow");
  const PAGES = [
    ["监控", [["overview", "仪表盘", ICON.dash], ["cpu", "CPU", ICON.cpu], ["gpu", "GPU", ICON.gpu], ["mem", "内存", ICON.mem], ["net", "网络", ICON.net], ["temp", "温度与风扇", ICON.fan]]],
    ["工具", [["processes", "进程", ICON.list], ["keepAwake", "防休眠", ICON.cup], ["cleaner", "清理", ICON.clean]]],
  ];
  const pageTitle = (id) => PAGES.flatMap(([, list]) => list).find(([p]) => p === id)[1];

  function overviewPage() {
    const maxFan = Math.max(...S.fans);
    const fanPct = Math.round((S.fans[0] / FAN_RANGE[0][1] + S.fans[1] / FAN_RANGE[1][1]) / 2 * 100);
    const cores = S.cores.slice(12).concat(S.cores.slice(0, 12));
    const coreBars = cores.map((v, i) => `${i === 6 ? '<i class="gap"></i>' : ""}<i><b style="height:${Math.round(v * 100)}%"></b></i>`).join("");
    const fanModes = [["auto", "自动"], ["cool", "降温"], ["max", "强冷"]].map(([m, t]) =>
      `<button class="op-chipbtn" type="button" data-fan="${m}" aria-pressed="${S.fanMode === m}">${t}</button>`).join("");

    return `<div class="op-health">
        <svg width="24" height="24" viewBox="0 0 24 24"><path class="fill-success" d="M12 1.5 14.6 3.4l3.2-.2 1 3 2.7 1.8-1 3.1 1 3.1-2.7 1.8-1 3-3.2-.2L12 22.5l-2.6-1.9-3.2.2-1-3-2.7-1.8 1-3.1-1-3.1 2.7-1.8 1-3 3.2.2z"/><path class="stroke-white" d="m8 12.2 2.6 2.6L16.2 9"/></svg>
        <span class="op-health__score">100</span><span class="op-health__text">各项指标正常</span>
      </div>
      <div class="op-badges">
        <span class="op-chip">${ICON.apple} M5 Max</span><span class="op-chip">64 GB</span><span class="op-chip">macOS 27.0</span>
        <span class="op-chip">已运行 3 天 4 小时</span><span class="op-chip">MacBook Pro 16 英寸</span>
      </div>
      <div class="op-row op-row--3">
        ${card(`CPU <span class="op-chip ${tempTone(S.cpuTemp)}">${Math.round(S.cpuTemp)}°C</span>`,
          `<div class="op-value">${Math.round(S.cpu * 100)}<small>%</small></div>${barsSVG(S.cpuHistory)}<div class="op-foot">${level(S.cpu)} · 负载 ${(S.cpu * 18).toFixed(1)}/18</div>`)}
        ${card(`GPU <span class="op-chip ${tempTone(S.gpuTemp)}">${Math.round(S.gpuTemp)}°C</span>`,
          `<div class="op-value">${Math.round(S.gpu * 100)}<small>%</small></div>${lineSVG(S.gpuHistory, { cls: "secondary" })}<div class="op-foot">${level(S.gpu)} · 40 核</div>`)}
        ${card(`内存 <span class="op-chip op-chip--success">压力 正常</span>`,
          `<div class="op-value">${Math.round(S.mem * 100)}<small>%</small></div>${lineSVG(S.memHistory)}<div class="op-foot">${(S.mem * 64).toFixed(1)} GB / 64.0 GB</div>`)}
      </div>
      <div class="op-row op-row--3">
        ${card(`磁盘 <span class="op-chip">2 TB</span>`,
          `<div class="op-value">16<small>%</small></div><div class="op-chart op-chart--center"><div class="op-track"><i style="width:16%"></i></div></div><div class="op-foot">可用 1.7 TB</div>`)}
        ${card(`网络 <span class="op-chip">Wi‑Fi</span>`,
          `<div class="op-value">${splitRate(S.up + S.down)}</div>${dualSVG(S.upHistory, S.downHistory)}<div class="op-foot"><span class="up-text">↑</span> ${rate(S.up)} <span class="down-text">↓</span> ${rate(S.down)}</div>`)}
        ${card(`风扇 <span class="op-chip">转速 ${fanPct}%</span>`,
          `<div class="op-value">${maxFan.toLocaleString("en-US")}<small>RPM</small></div><div class="op-foot">${S.fanMode === "auto" ? "由 macOS 调节" : "OpenStats 控制中"}</div><div class="op-chipgrid op-chipgrid--3">${fanModes}</div>`)}
      </div>
      <div class="op-row op-row--2-1">
        ${card(`核心负载 <span class="op-legend"><i class="bg-primary"></i>用户 <b>${Math.round(S.cpu * 72)}%</b></span><span class="op-legend"><i class="bg-secondary"></i>系统 <b>${Math.round(S.cpu * 28)}%</b></span>`,
          `<div class="op-cores">${coreBars}</div><div class="op-core-labels"><span>超级核 · 6</span><span>性能核 · 12</span></div>`)}
        ${card(`电池 <span class="op-chip">健康 100%</span>`,
          `<div class="op-battery"><div><div class="op-value">100%</div><div class="op-foot">已充满 · 电源适配器</div><div class="op-foot">循环 28 次</div></div>${ringSVG(1, 56, 6, "ring-success")}</div>`)}
      </div>
      <div class="op-row op-row--2-1">
        ${card(`高占用进程 <span class="op-card__note">CPU · 内存</span>`, procRows([...PROCESSES].sort((a, b) => b.cpu - a.cpu).slice(0, 5), [cpuText, memText]))}
        ${card("快捷开关", `
          <button class="op-quick" type="button" data-action="awake" aria-pressed="${S.keepAwake}">${ICON.cup}<span>防休眠</span><span>${S.keepAwake ? "已开启" : "关闭"}</span></button>
          <button class="op-quick" type="button" data-action="lid" aria-pressed="${S.lidClosed}">${ICON.laptop}<span>合盖运行</span><span>${S.lidClosed ? "已开启" : "关闭"}</span></button>
          <button class="op-quick" type="button" data-page="temp" aria-pressed="${S.fanMode !== "auto"}">${ICON.fan}<span>散热模式</span><span>${{ auto: "自动", cool: "降温", max: "强冷", custom: "自定义" }[S.fanMode]}</span></button>`)}
      </div>`;
  }

  function processesPage() {
    const list = [...PROCESSES].sort((a, b) => (S.sort === "cpu" ? b.cpu - a.cpu : b.mem - a.mem));
    return `<div class="op-seg op-seg--narrow">
        <button type="button" data-sort="cpu" aria-pressed="${S.sort === "cpu"}">按 CPU</button>
        <button type="button" data-sort="mem" aria-pressed="${S.sort === "mem"}">按内存</button>
      </div>
      ${card(`进程 <span class="op-card__note">占用最高的 ${list.length} 个</span>`, procRows(list, [cpuText, memText]))}
      <div class="op-foot">仅列出当前用户有权限读取的进程，CPU 以单核满载为 100%。</div>`;
  }

  function thermalPage() {
    const temps = [["CPU", S.cpuTemp], ["GPU", S.gpuTemp], ["内存", S.memTemp], ["电池", S.batteryTemp], ["掌托", S.palmTemp]]
      .map(([t, v]) => `<div class="op-list-row"><span class="op-list-row__title">${t}</span><div class="op-track"><i class="${v >= 80 ? "bg-warning" : ""}" style="width:${Math.round(v / 110 * 100)}%"></i></div><span class="op-list-row__value">${Math.round(v)}°C</span></div>`).join("");
    const fans = S.fans.map((rpm, i) => {
      const [lo, hi] = FAN_RANGE[i];
      return `<div class="op-list-row"><span class="op-list-row__title">${i ? "右侧" : "左侧"}</span><div class="op-track"><i class="bg-secondary" style="width:${Math.round((rpm - lo) / (hi - lo) * 100)}%"></i></div><span class="op-list-row__value">${rpm}</span></div>`;
    }).join("");
    const modes = [["auto", "自动"], ["cool", "降温"], ["max", "强冷"], ["custom", "自定义"]]
      .map(([m, t]) => `<button type="button" data-fan="${m}" aria-pressed="${S.fanMode === m}">${t}</button>`).join("");
    return `<div class="op-row op-row--2">
      ${card(`温度 <span class="op-card__note">41 个传感器</span>`, temps)}
      ${card(`风扇 <span class="op-chip ${S.fanMode === "auto" ? "" : "op-chip--primary"}">${S.fanMode === "auto" ? "系统自动" : "OpenStats 控制"}</span>`,
        `${fans}<div class="op-seg">${modes}</div><div class="op-foot">这是网页演示，不会改动你电脑的风扇。</div>`)}
    </div>`;
  }

  function keepAwakePage() {
    const modes = [["display", "屏幕保持常亮", "屏幕和系统都不会因闲置而关闭或休眠"], ["system", "仅系统不休眠", "屏幕可按设置关闭，后台任务继续运行"]]
      .map(([m, t, d]) => `<button class="op-radio" type="button" role="radio" data-awake-mode="${m}" aria-checked="${S.awakeMode === m}"><i></i><span><b>${t}</b><small>${d}</small></span></button>`).join("");
    const durations = [[15, "15 分钟"], [60, "1 小时"], [120, "2 小时"], [300, "5 小时"], [0, "不限"]]
      .map(([m, t]) => `<button type="button" data-duration="${m}" aria-pressed="${S.duration === m}">${t}</button>`).join("");
    return `<div class="op-card"><div class="op-list-row">
        <span class="op-value">防休眠</span>
        <span class="op-foot">${S.keepAwake ? "已开启 · " + (S.duration ? `${S.duration} 分钟后恢复` : "不限时") : "未开启，Mac 按系统设置休眠"}</span>
        <button class="op-toggle" type="button" role="switch" data-action="awake" aria-checked="${S.keepAwake}" aria-label="防休眠"></button>
      </div></div>
      <div class="op-row op-row--2">
        <div class="op-card"><div class="op-card__head">模式</div>${modes}<div class="op-card__head">持续时间</div><div class="op-seg">${durations}</div></div>
        <div class="op-card">
          <div class="op-list-row"><span><b>合盖后继续运行</b><br><span class="op-foot">合上屏幕时 Mac 不进入睡眠</span></span>
          <button class="op-toggle" type="button" role="switch" data-action="lid" aria-checked="${S.lidClosed}" aria-label="合盖后继续运行"></button></div>
          <div class="op-banner">${ICON.warn}<span>合盖运行时散热变差，请勿放入包中。使用电池且电量低于 20% 时会自动关闭。</span></div>
        </div>
      </div>`;
  }

  function cleanerPage() {
    const selected = CLEAN_RULES.filter((r) => r.on && !r.blocked && !S.cleaned);
    const total = selected.reduce((a, r) => a + r.size, 0);
    const cats = [...new Set(CLEAN_RULES.map((r) => r.cat))];
    const groups = cats.map((cat) => card(cat, CLEAN_RULES.filter((r) => r.cat === cat).map((r) => `
      <div class="op-clean-row">
        <button class="op-check" type="button" role="checkbox" data-rule="${r.id}" aria-checked="${r.on && !r.blocked}" ${r.blocked || S.cleaned ? "disabled" : ""} aria-label="${r.title}"></button>
        <span><b>${r.title}</b><small class="${r.blocked ? "warning-text" : ""}">${S.cleaned && r.on ? "无需清理" : r.detail}</small></span>
        <span class="size">${r.blocked || (S.cleaned && r.on) ? "" : bytes(r.size)}</span>
      </div>`).join(""))).join("");

    let action;
    if (S.cleaned) {
      action = `<div class="op-banner op-banner--success">${ICON.check}<span>已释放 ${bytes(CLEAN_RULES.filter((r) => r.on && !r.blocked).reduce((a, r) => a + r.size, 0))}（网页演示，没有删除任何文件）</span></div>
        <div class="op-actions"><button class="op-btn" type="button" data-action="rescan">重新扫描</button></div>`;
    } else if (S.confirming) {
      action = `<div class="op-banner">${ICON.warn}<span>将清理 ${selected.length} 类项目，共 ${bytes(total)}。缓存与日志直接删除，下载内容移到废纸篓。</span></div>
        <div class="op-actions"><button class="op-btn" type="button" data-action="cancel">取消</button><button class="op-btn op-btn--primary" type="button" data-action="confirm">确认清理</button></div>`;
    } else {
      action = `<div class="op-actions"><button class="op-btn" type="button" data-action="rescan">重新扫描</button>
        <button class="op-btn op-btn--primary" type="button" data-action="clean" ${total ? "" : "disabled"}>${S.cleaning ? "清理中…" : `清理所选 ${bytes(total)}`}</button></div>`;
    }

    return `${card(`磁盘清理 <span class="op-card__note">扫描于 刚刚</span>`, `
        <div class="op-value">${bytes(S.cleaned ? 0 : CLEAN_RULES.filter((r) => !r.blocked).reduce((a, r) => a + r.size, 0))}<small>可清理</small></div>
        <div class="op-track"><i style="width:16%"></i></div><div class="op-foot">Macintosh HD 可用 1.7 TB · 共 2.0 TB</div>${action}`)}
      <div class="op-row op-row--2">${groups}</div>`;
  }

  const WINDOW_PAGES = {
    overview: overviewPage, processes: processesPage, keepAwake: keepAwakePage, cleaner: cleanerPage,
    cpu: () => CONTENT.cpu(true), gpu: () => CONTENT.gpu(true), mem: () => CONTENT.mem(true), net: () => CONTENT.net(true), temp: () => CONTENT.temp(true),
  };

  function renderWindow() {
    if (!S.windowOpen) { appWindow.hidden = true; return; }
    const scroller = appWindow.querySelector(".ow-content");
    const scroll = scroller ? scroller.scrollTop : 0;
    const nav = PAGES.map(([group, list]) => `<div class="ow-group">${group}</div>` + list.map(([id, title, icon]) =>
      `<button class="ow-nav" type="button" data-page="${id}" aria-current="${S.page === id ? "page" : "false"}">${icon}<span>${title}</span></button>`).join("")).join("");
    const toggle = ITEM_META[S.page]
      ? `<span class="ow-toggle-label">在菜单栏显示</span><button class="op-toggle" type="button" role="switch" data-action="menubar-item" aria-checked="${S.items.includes(S.page)}" aria-label="在菜单栏显示${pageTitle(S.page)}"></button>`
      : "";
    appWindow.innerHTML = `
      <aside class="ow-sidebar">
        <div class="ow-lights ow-drag"><button type="button" data-action="window-close" aria-label="关闭窗口"></button><i></i><i></i></div>
        <nav class="ow-navlist" aria-label="OpenStats 页面">${nav}</nav>
        <div class="ow-tools">
          <button class="op-icon" type="button" data-action="theme" aria-label="切换浅色 / 深色">${ICON.moon}</button>
          <button class="op-icon" type="button" data-action="settings" aria-label="设置">${ICON.gear}</button>
          <button class="op-icon" type="button" data-action="window-close" aria-label="关闭窗口">${ICON.power}</button>
        </div>
      </aside>
      <section class="ow-main">
        <header class="ow-header ow-drag"><h2>${pageTitle(S.page)}</h2>${toggle}</header>
        <div class="ow-content">${WINDOW_PAGES[S.page]()}</div>
      </section>`;
    appWindow.hidden = false;
    appWindow.querySelector(".ow-content").scrollTop = scroll;
  }

  function openWindow(page) {
    if (page) S.page = page;
    S.windowOpen = true;
    closePopover();
    renderWindow();
    document.getElementById("dockOpenStats")?.classList.add("dock__item--running");
  }

  // ── 交互 ──────────────────────────────────────────────────
  function handle(target, event) {
    const d = target.dataset;
    if (d.copy) {
      navigator.clipboard?.writeText(d.copy).catch(() => {});
      target.textContent = "已拷贝";
      target.classList.add("is-copied");
      setTimeout(() => { target.textContent = d.copy; target.classList.remove("is-copied"); }, 1200);
      return false;
    }
    if (d.item) { event.stopPropagation(); openPopover(d.item); return false; }
    if (d.page) S.page = d.page;
    if (d.fan) S.fanMode = d.fan;
    if (d.sort) S.sort = d.sort;
    if (d.awakeMode) S.awakeMode = d.awakeMode;
    if (d.duration !== undefined) S.duration = Number(d.duration);
    if (d.dns) { S.dns = d.dns; S.dnsManual = false; S.dnsNote = "网页演示：没有修改你电脑的 DNS。"; }
    if (d.rule) { const r = CLEAN_RULES.find((x) => x.id === d.rule); r.on = !r.on; S.confirming = false; }
    switch (d.action) {
      case "theme": window.OpenStatsSite?.toggleTheme(); break;
      case "settings": closePopover(); document.getElementById("styles").scrollIntoView(); return false;
      case "window": openWindow(S.popover === "temp" ? "temp" : S.popover || null); return false;
      case "window-close": S.windowOpen = false; renderWindow(); return false;
      case "menubar-item": {
        S.items = S.items.includes(S.page) ? S.items.filter((k) => k !== S.page) : [...S.items, S.page];
        write("os-items", S.items.join(","));
        break;
      }
      case "dns-manual": S.dnsManual = !S.dnsManual; break;
      case "flush": S.dnsNote = "DNS 缓存已刷新（网页演示）"; break;
      case "lookup": S.dnsNote = ""; break;
      case "purge": target.textContent = "已释放 1.2 GB（网页演示）"; target.disabled = true; return false;
      case "awake": S.keepAwake = !S.keepAwake; if (!S.keepAwake) S.lidClosed = false; break;
      case "lid": S.lidClosed = !S.lidClosed; if (S.lidClosed) S.keepAwake = true; break;
      case "clean": S.confirming = true; break;
      case "cancel": S.confirming = false; break;
      case "confirm": S.confirming = false; S.cleaning = true; setTimeout(() => { S.cleaning = false; S.cleaned = true; renderWindow(); }, 900); break;
      case "rescan": S.cleaned = false; S.confirming = false; break;
    }
    return true;
  }

  document.addEventListener("click", (event) => {
    const target = event.target.closest("[data-item], [data-page], [data-fan], [data-sort], [data-awake-mode], [data-duration], [data-dns], [data-rule], [data-action], [data-copy]");
    const inPopover = popover.contains(event.target);
    const inWindow = appWindow.contains(event.target);
    const inBar = itemsBox?.contains(event.target);
    if (target && (inPopover || inWindow || inBar)) {
      if (inPopover || inWindow) event.stopPropagation();
      if (handle(target, event)) { renderMenubar(); renderPopover(); renderWindow(); }
      return;
    }
    if (S.popover && !inPopover) closePopover();
  });

  document.addEventListener("submit", (event) => {
    const form = event.target.closest('[data-form="dns"]');
    if (!form) return;
    event.preventDefault();
    const input = form.elements.servers;
    const parts = input.value.split(/[\s,，]+/).filter(Boolean);
    const ipv4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;
    const valid = parts.length > 0 && parts.length <= 6 && parts.every((p) => ipv4.test(p) || /^[0-9a-f:]+$/i.test(p) && p.includes(":"));
    S.dnsNote = valid ? `网页演示：会把 DNS 设为 ${parts.join("、")}，没有修改你的电脑。` : "地址格式不正确，只接受 IPv4 / IPv6 地址。";
    if (valid) S.dnsManual = false;
    renderPopover();
    renderWindow();
  });

  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closePopover(); });
  window.addEventListener("resize", () => { if (S.popover) placePopover(); });
  document.getElementById("dockOpenStats")?.addEventListener("click", (e) => { e.stopPropagation(); openWindow(); });
  document.getElementById("heroOpenWindow")?.addEventListener("click", (e) => { e.stopPropagation(); openWindow("net"); });

  // 按住窗口顶栏或侧边栏顶部拖动（仅桌面宽度）
  appWindow.addEventListener("pointerdown", (event) => {
    const handleBar = event.target.closest(".ow-drag");
    if (!handleBar || event.target.closest("button") || window.innerWidth < 900) return;
    const start = { x: event.clientX, y: event.clientY, left: appWindow.offsetLeft, top: appWindow.offsetTop };
    const move = (e) => {
      appWindow.style.left = `${start.left + e.clientX - start.x}px`;
      appWindow.style.top = `${Math.max(28, start.top + e.clientY - start.y)}px`;
      appWindow.style.transform = "none";
    };
    const up = () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  });

  // ── 刘海岛、风格选择 ───────────────────────────────────────
  const bind = (key, fn) => document.querySelectorAll(`[data-bind="${key}"]`).forEach(fn);
  function renderIsland() {
    bind("island-cpu", (el) => { el.textContent = `CPU ${pct(S.cpu)} · ${Math.round(S.cpuTemp)}°`; });
    const tiles = { cpu: [S.cpu, pct(S.cpu)], gpu: [S.gpu, pct(S.gpu)], mem: [S.mem, pct(S.mem)], temp: [S.cpuTemp / 110, `${Math.round(S.cpuTemp)}°`] };
    for (const [k, [f, text]] of Object.entries(tiles)) {
      bind(`island-${k}-value`, (el) => { el.textContent = text; });
      bind(`island-${k}-bar`, (el) => { el.style.width = `${Math.round(clamp(f, 0, 1) * 100)}%`; });
    }
    bind("island-up", (el) => { el.textContent = rate(S.up); });
    bind("island-down", (el) => { el.textContent = rate(S.down); });
    bind("island-fan", (el) => { el.textContent = `风扇 ${Math.max(...S.fans).toLocaleString("en-US")} RPM`; });
  }

  const picker = document.getElementById("stylePicker");
  if (picker) {
    picker.innerHTML = STYLES.map(([id, title]) =>
      `<button class="style-chip" type="button" role="radio" data-style="${id}" aria-checked="${S.style === id}">${title}</button>`).join("");
  }
  function renderStyles() {
    if (!picker) return;
    picker.querySelectorAll("[data-style]").forEach((chip) => chip.setAttribute("aria-checked", String(chip.dataset.style === S.style)));
    const preview = ["cpu", "mem", "gpu"].map((k) => `<span class="mb-stats mb-stats--static">${itemHTML(k, S.style)}</span>`).join("");
    document.getElementById("stylePreviewLight").innerHTML = preview;
    document.getElementById("stylePreviewDark").innerHTML = preview;
    document.getElementById("styleCaption").textContent = STYLES.find(([id]) => id === S.style)[2];
  }
  picker?.addEventListener("click", (e) => {
    const chip = e.target.closest("[data-style]");
    if (!chip) return;
    S.style = chip.dataset.style;
    write("os-style", S.style);
    renderStyles();
    renderMenubar();
  });

  const island = document.getElementById("island");
  const setIsland = (open) => {
    island.classList.toggle("is-open", open);
    island.setAttribute("aria-expanded", String(open));
    island.querySelector(".island__expanded").setAttribute("aria-hidden", String(!open));
  };
  island.addEventListener("mouseenter", () => setIsland(true));
  island.addEventListener("mouseleave", () => setIsland(false));
  island.addEventListener("click", (e) => { e.stopPropagation(); setIsland(!island.classList.contains("is-open")); });

  // ── 循环 ──────────────────────────────────────────────────
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const editing = (el) => el.contains(document.activeElement) && document.activeElement.matches("input");
  // 按下后 1 秒内不重绘：触屏没有悬停状态，按下与抬起之间换掉按钮会让点击落空
  let holdUntil = 0;
  for (const el of [popover, appWindow]) {
    el.addEventListener("pointerdown", () => { holdUntil = Date.now() + 1000; }, true);
  }
  const busy = (el) => Date.now() < holdUntil || el.matches(":hover") || editing(el);
  function frame() {
    tick();
    renderMenubar();
    renderIsland();
    renderStyles();
    if (S.popover && !busy(popover)) renderPopover();
    if (S.windowOpen && !busy(appWindow)) renderWindow();
  }
  frame();
  if (!reduced) setInterval(frame, 1500);
})();
