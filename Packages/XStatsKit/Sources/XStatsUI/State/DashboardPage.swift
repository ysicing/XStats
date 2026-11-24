// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

enum DashboardPage {
  private static let languages = AppLanguage.allCases.filter { $0 != .system }
  static let languagePath = "/dashboard/locale/"

  static func language(for code: String) -> AppLanguage? {
    languages.first(where: { $0.languageCode == code })
  }

  static func localization(for code: String) -> Data? {
    guard let language = language(for: code) else { return nil }
    return try? JSONEncoder().encode(labels(language))
  }

  private static func labels(_ language: AppLanguage) -> [String: String] {
    let text = { (key: String) in L10n.translate(key, language: language) }
    return [
      "title": text("监控大屏"), "language": text("语言"), "followApp": text("跟随 XStats"),
      "appearance": text("外观"), "system": text("系统"), "light": text("浅色"), "dark": text("深色"),
      "displaySettings": text("显示设置"), "back": text("返回"), "resources": text("系统资源"),
      "loadAverage": text("1 / 5 / 15 分钟负载"), "cores": text("核心负载"),
      "download": text("下载"), "upload": text("上传"), "trend": text("近 5 分钟"),
      "sampling": text("等待采样"), "paused": text("已暂停"), "unavailable": text("没有启用的监控指标"),
      "offline": text("连接中断，正在重试"), "memory": text("内存"), "network": text("网络"),
      "disk": text("磁盘"), "battery": text("电池"), "charging": text("正在充电"),
      "plugged": text("电源适配器"), "onBattery": text("使用电池"),
      "topProcesses": text("CPU 占用最高的进程"), "process": text("进程"),
    ]
  }

  static func html(language: AppLanguage) -> String {
    let labels = labels(language)
    let text = { (key: String) in
      (labels[key] ?? "").replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
    }
    let initialLabels =
      (try? JSONEncoder().encode(labels))
      .map { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c") }
      ?? "{}"
    let options = languages.map {
      """
      <label><input type="radio" name="language" value="\($0.languageCode)">
        <bdi lang="\($0.languageCode)">\($0.nativeName)</bdi></label>
      """
    }.joined(separator: "\n")
    return """
      <!doctype html>
      <html lang="\(language.languageCode)" dir="\(language.isRightToLeft ? "rtl" : "ltr")">
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>XStats · \(text("title"))</title>
      <style>
        :root { color-scheme: light; --bg: #f7f7f8; --surface: #ffffff; --text: #1a1b1e;
          --muted: #545a65; --line: #d1d4db; --track: #e4e6eb; --selected: #dadee7;
          --accent: #007c72; --blue: #1765ca; }
        :root[data-theme="dark"] { color-scheme: dark; --bg: #111316; --surface: #202226;
          --text: #f4f5f7; --muted: #b6bbc5; --line: #3b424b; --track: #30343b;
          --selected: #454950; --accent: #48dbc6; --blue: #62a8ff; }
        @media (prefers-color-scheme: dark) {
          :root:not([data-theme]) { color-scheme: dark; --bg: #111316; --surface: #202226;
            --text: #f4f5f7; --muted: #b6bbc5; --line: #3b424b; --track: #30343b;
            --selected: #454950; --accent: #48dbc6; --blue: #62a8ff; }
        }
        * { box-sizing: border-box; }
        [hidden] { display: none !important; }
        body { margin: 0; background: var(--bg); color: var(--text);
          font: 1rem/1.45 system-ui, sans-serif; }
        main { max-width: 105rem; margin: auto; padding: 0 clamp(1rem, 2.25vw, 2.5rem); }
        header { display: flex; justify-content: space-between; align-items: center; gap: .65rem 1.5rem;
          flex-wrap: wrap; padding-block: 1rem; border-block-end: 1px solid var(--line); }
        h1, h2, h3, p, fieldset { margin: 0; }
        h1 { font-size: clamp(1.35rem, 2.6vw, 2.125rem); line-height: 1.12; letter-spacing: -.025em; }
        h2 { font-size: clamp(1.25rem, 2.1vw, 1.75rem); line-height: 1.2; letter-spacing: -.017em; }
        h3 { font-size: 1.05rem; font-weight: 650; }
        small, #status, #calendar, .muted { color: var(--muted); }
        #status:empty { display: none; }
        #updated { font-size: 1.15rem; font-variant-numeric: tabular-nums; }
        #calendar { font-size: .88rem; overflow-wrap: anywhere; }
        .toolbar { display: flex; align-items: center; gap: 1.15rem; margin-inline-start: auto; }
        .clock { text-align: end; }
        .preferences { position: relative; }
        button { color: inherit; font: inherit; cursor: pointer; }
        button:focus-visible, input:focus-visible + span, .languages label:has(:focus-visible) {
          outline: 2px solid var(--blue); outline-offset: 2px;
        }
        .settings-toggle { display: grid; place-items: center; width: 2.75rem; height: 2.75rem;
          padding: 0; border: 1px solid var(--line); border-radius: .7rem; background: var(--surface); }
        .settings-toggle:hover, .settings-toggle[aria-expanded="true"] { background: var(--track); }
        .settings-toggle svg { width: 1.2rem; }
        .settings-panel { position: absolute; z-index: 1; inset-inline-end: 0; inset-block-start: calc(100% + .6rem);
          width: min(20rem, calc(100vw - 2rem)); padding: .9rem; border: 1px solid var(--line);
          max-height: min(29rem, calc(100dvh - 8rem)); overflow-y: auto; border-radius: .9rem;
          background: var(--surface); box-shadow: 0 .6rem 1.8rem #0003; font-size: .93rem; }
        fieldset { padding: 0; border: 0; min-inline-size: 0; }
        legend { padding: 0; font-weight: 600; }
        .segments { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: .2rem; margin-block-start: .45rem; padding: .2rem; border-radius: .6rem; background: var(--track); }
        .segments label { position: relative; text-align: center; cursor: pointer; }
        .segments input { position: absolute; opacity: 0; }
        .segments span { display: grid; place-items: center; min-height: 2.25rem; padding: .25rem;
          border-radius: .45rem; overflow-wrap: anywhere; }
        .segments input:checked + span { background: var(--selected); font-weight: 650; }
        .language-link, .language-back { display: flex; align-items: center; gap: .55rem;
          padding: .55rem .25rem; border: 0; background: transparent; min-height: 2.5rem; }
        .language-link { width: 100%; margin-block-start: .65rem; border-block-start: 1px solid var(--line);
          padding-block-end: 0; text-align: start; }
        .language-link bdi { margin-inline-start: auto; text-align: end; color: var(--muted); }
        .chevron { width: .45rem; height: .45rem; border-block-start: 1.5px solid;
          border-inline-end: 1.5px solid; transform: rotate(45deg); flex: none; }
        :root[dir="rtl"] .chevron { transform: rotate(-45deg); }
        .language-back .chevron { scale: -1 1; }
        .language-back { color: var(--blue); margin-block-end: .3rem; }
        .languages label { display: flex; align-items: center; gap: .65rem; min-height: 2.25rem;
          padding: .18rem .35rem; border-radius: .4rem; cursor: pointer; }
        .languages label:hover, .language-link:hover { background: var(--track); }
        input { accent-color: var(--blue); }
        .dashboard { display: grid; grid-template-columns: minmax(0, 1.18fr) minmax(0, 1fr);
          padding-block: clamp(1.2rem, 2vw, 1.8rem); }
        .column { min-width: 0; padding-inline: clamp(.75rem, 2vw, 2rem); }
        .resources { padding-inline-start: .75rem; }
        .activity { border-inline-start: 1px solid var(--line); padding-inline-end: .15rem; }
        .column:has(+ .column[hidden]), .column[hidden] + .column { grid-column: 1 / -1;
          padding-inline: .75rem; border: 0; }
        .resources > h2 { margin-block-end: 1.85rem; }
        #memory, .capacity, #processes { border-block-start: 1px solid var(--line);
          margin-block-start: clamp(1.25rem, 2.1vw, 2rem); padding-block-start: 1.25rem; }
        #cpu[hidden] + #memory, #network[hidden] + #processes {
          margin-block-start: 0; padding-block-start: 0; border: 0; }
        .readout { display: flex; flex-wrap: wrap; align-items: baseline; gap: .2rem .45rem;
          margin-block: .32rem .45rem; }
        .value { font-size: clamp(1.55rem, 2.8vw, 2.65rem); font-weight: 650;
          line-height: 1.12; letter-spacing: -.025em; font-variant-numeric: tabular-nums; }
        .value, [data-detail] { overflow-wrap: anywhere; }
        .total { font-size: clamp(1rem, 1.8vw, 1.6rem); color: var(--muted); }
        .cpu-readout { display: flex; flex-wrap: wrap; align-items: center; gap: .4rem 2.5rem; }
        #cpu .value { font-size: clamp(2.65rem, 4.2vw, 4.2rem); margin-block: .35rem; }
        .load { font-variant-numeric: tabular-nums; }
        .load small { display: block; }
        .rates { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: .55rem 1rem;
          margin-block: .9rem .55rem; }
        .rates .value { display: block; font-size: clamp(1.25rem, 2.3vw, 2.1rem); margin-block-start: .22rem; }
        #down-rate { color: var(--accent); }
        #up-rate { color: var(--blue); }
        canvas { display: block; width: 100%; height: clamp(5rem, 10vw, 9rem); margin-block-start: .85rem; }
        #memory canvas { height: clamp(3.25rem, 6vw, 5.1rem); }
        .chart-window { display: block; text-align: end; margin-block-start: .25rem; }
        .core-load { display: flex; align-items: start; flex-wrap: wrap; gap: .35rem 1rem; margin-block-start: .8rem; }
        .cores { flex: 1 1 14rem; display: grid; grid-template-columns: repeat(auto-fit, minmax(2.5rem, 1fr));
          gap: .35rem .55rem; text-align: center; font-variant-numeric: tabular-nums; }
        meter { display: block; width: 100%; height: .6rem; accent-color: var(--blue);
          appearance: none; background: var(--track); border-radius: 10rem; }
        meter::-webkit-meter-bar { background: var(--track); border: 0; height: .6rem; border-radius: 10rem; }
        meter::-webkit-meter-optimum-value { background: var(--blue); border-radius: 10rem; }
        meter::-moz-meter-bar { background: var(--blue); border-radius: 10rem; }
        .capacity { display: flex; flex-wrap: wrap; gap: 1rem 0; }
        .capacity article { flex: 1 1 6rem; min-width: 0; padding-inline: 1rem; }
        .capacity article:first-of-type { flex-grow: 1.8; }
        .capacity article:first-of-type, .capacity article[hidden] + article { padding-inline-start: 0; }
        .capacity article:not([hidden]) ~ article:not([hidden]) {
          border-inline-start: 1px solid var(--line); padding-inline-start: 1rem; }
        .capacity .value { font-size: clamp(1.35rem, 2.25vw, 2rem); }
        .capacity .total { font-size: clamp(.9rem, 1.3vw, 1.2rem); }
        table { width: 100%; margin-block-start: .85rem; border-collapse: collapse; }
        th, td { text-align: start; padding: .55rem .3rem; border-block-end: 1px solid var(--line); }
        th { font-size: .875rem; color: var(--muted); font-weight: 550; }
        td:first-child { overflow-wrap: anywhere; font-weight: 550; }
        :is(th, td):not(:first-child) { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
        @media (max-width: 55rem) {
          .dashboard { display: block; }
          .column, .column:has(+ .column[hidden]), .column[hidden] + .column { padding-inline: 0; }
          .activity { border: 0; }
          .resources:not([hidden]) + .activity { margin-block-start: 1.5rem; padding-block-start: 1.5rem;
            border-block-start: 1px solid var(--line); }
        }
        @media (max-width: 34rem) { .toolbar { gap: .75rem; } }
        @media (prefers-reduced-transparency: no-preference) {
          .settings-panel { background: color-mix(in srgb, var(--surface) 94%, transparent);
            backdrop-filter: blur(16px); }
        }
        @media (prefers-contrast: more) { :root { --line: var(--muted); } }
      </style>
      <main>
        <header>
          <h1>XStats · <span data-label="title">\(text("title"))</span></h1>
          <div class="toolbar">
            <div class="clock">
              <p id="status" role="status">\(text("sampling"))</p>
              <time id="updated"></time>
              <p id="calendar" dir="auto" hidden></p>
            </div>
            <div class="preferences">
              <button id="settings-toggle" class="settings-toggle" type="button"
                aria-expanded="false" aria-controls="settings-panel" aria-label="\(text("displaySettings"))"
                title="\(text("displaySettings"))">
                <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                  stroke-width="1.6" stroke-linecap="round">
                  <path d="M3 6h5m4 0h9M3 12h10m4 0h4M3 18h3m4 0h11"/>
                  <circle cx="10" cy="6" r="2"/><circle cx="15" cy="12" r="2"/><circle cx="8" cy="18" r="2"/>
                </svg>
              </button>
              <div id="settings-panel" class="settings-panel" role="group"
                aria-labelledby="settings-toggle" hidden>
                <div id="settings-home">
                  <fieldset>
                    <legend data-label="appearance">\(text("appearance"))</legend>
                    <div class="segments">
                      <label><input type="radio" name="theme" value="system" checked>
                        <span data-label="system">\(text("system"))</span></label>
                      <label><input type="radio" name="theme" value="light">
                        <span data-label="light">\(text("light"))</span></label>
                      <label><input type="radio" name="theme" value="dark">
                        <span data-label="dark">\(text("dark"))</span></label>
                    </div>
                  </fieldset>
                  <button id="language-link" class="language-link" type="button"
                    aria-controls="language-panel" aria-expanded="false">
                    <span data-label="language">\(text("language"))</span>
                    <bdi id="current-language">\(text("followApp"))</bdi>
                    <span class="chevron" aria-hidden="true"></span>
                  </button>
                </div>
                <div id="language-panel" hidden>
                  <button id="language-back" class="language-back" type="button">
                    <span class="chevron" aria-hidden="true"></span><span data-label="back">\(text("back"))</span>
                  </button>
                  <fieldset class="languages">
                    <legend data-label="language">\(text("language"))</legend>
                    <label><input type="radio" name="language" value="" checked>
                      <bdi data-label="followApp">\(text("followApp"))</bdi></label>
                    \(options)
                  </fieldset>
                </div>
              </div>
            </div>
          </div>
        </header>
        <div class="dashboard">
          <section class="column resources" aria-labelledby="resources-heading" hidden>
            <h2 id="resources-heading" data-label="resources">\(text("resources"))</h2>
            <article id="cpu" hidden>
              <h3>CPU</h3>
              <div class="cpu-readout"><p class="value"></p><p class="load">
                <span data-detail></span><small data-label="loadAverage">\(text("loadAverage"))</small>
              </p></div>
              <canvas aria-hidden="true"></canvas>
              <div class="core-load"><small data-label="cores">\(text("cores"))</small><div class="cores"></div></div>
            </article>
            <article id="memory" hidden>
              <h3 data-label="memory">\(text("memory"))</h3>
              <p class="readout"><span class="value"></span><span class="total" data-detail></span></p>
              <canvas aria-hidden="true"></canvas>
            </article>
            <div class="capacity" hidden>
              <article id="disk" hidden>
                <h3 data-label="disk">\(text("disk"))</h3>
                <p class="readout"><span class="value"></span><span class="total" data-detail></span></p>
                <meter min="0" max="1" aria-label="\(text("disk"))"></meter>
              </article>
              <article id="gpu" hidden>
                <h3>GPU</h3><p class="readout value"></p>
              </article>
              <article id="battery" hidden>
                <h3 data-label="battery">\(text("battery"))</h3>
                <p class="readout value"></p><small data-detail></small>
              </article>
            </div>
          </section>
          <section class="column activity" hidden>
            <article id="network" hidden>
              <h2 data-label="network">\(text("network"))</h2>
              <div class="rates">
                <p><span data-label="download">\(text("download"))</span><bdi id="down-rate" class="value"></bdi></p>
                <p><span data-label="upload">\(text("upload"))</span><bdi id="up-rate" class="value"></bdi></p>
              </div>
              <small data-detail dir="auto" hidden></small>
              <canvas aria-hidden="true"></canvas>
              <small class="chart-window" data-label="trend">\(text("trend"))</small>
            </article>
            <article id="processes" hidden>
              <h2 data-label="topProcesses">\(text("topProcesses"))</h2>
              <table><thead><tr><th scope="col" data-label="process">\(text("process"))</th><th scope="col">CPU</th>
                <th scope="col" data-label="memory">\(text("memory"))</th></tr></thead><tbody></tbody></table>
            </article>
          </section>
        </div>
      </main>
      <script id="dashboard-labels" type="application/json">\(initialLabels)</script>
      <script src="/dashboard.js" defer></script>
      </html>
      """
  }

  static let script = """
    'use strict';
    const status = document.querySelector('#status');
    const updated = document.querySelector('#updated');
    const calendar = document.querySelector('#calendar');
    const page = document.documentElement;
    const defaultLanguage = page.lang;
    let appLanguage = defaultLanguage;
    const defaultLabels = JSON.parse(document.querySelector('#dashboard-labels').textContent);
    const settingsToggle = document.querySelector('#settings-toggle');
    const settingsPanel = document.querySelector('#settings-panel');
    const settingsHome = document.querySelector('#settings-home');
    const languagePanel = document.querySelector('#language-panel');
    const languageLink = document.querySelector('#language-link');
    const languageBack = document.querySelector('#language-back');
    const currentLanguage = document.querySelector('#current-language');
    const languageInputs = [...document.querySelectorAll('input[name="language"]')];
    const themes = [...document.querySelectorAll('input[name="theme"]')];
    const resources = document.querySelector('.resources');
    const capacity = document.querySelector('.capacity');
    const activity = document.querySelector('.activity');
    const diskMeter = document.querySelector('#disk meter');
    const systemTheme = matchMedia('(prefers-color-scheme: dark)');
    const history = [];
    let labels = defaultLabels;
    let state = 'sampling';
    let languageSelection = '';
    let themeSelection = 'system';
    let percent, number, clock, latestReading, timer, request, languageRequest;
    let calendarKey, calendarRequest, calendarRetryAt = 0;

    function preference(key, value) {
      try {
        if (value === undefined) return localStorage.getItem(key);
        localStorage.setItem(key, value);
      } catch {}
    }

    function setStatus(value) {
      state = value;
      const message = state === 'live' ? '' : (labels[state] ?? labels.sampling);
      if (status.textContent !== message) status.textContent = message;
    }

    function applyLanguage(code, translated) {
      labels = translated;
      page.lang = code;
      page.dir = code === 'ar' ? 'rtl' : 'ltr';
      document.title = `XStats · ${labels.title}`;
      document.querySelectorAll('[data-label]').forEach(element => {
        element.textContent = labels[element.dataset.label];
      });
      settingsToggle.setAttribute('aria-label', labels.displaySettings);
      settingsToggle.title = labels.displaySettings;
      diskMeter.setAttribute('aria-label', labels.disk);
      percent = new Intl.NumberFormat(code, {style: 'percent', maximumFractionDigits: 1});
      number = new Intl.NumberFormat(code, {maximumFractionDigits: 1});
      clock = new Intl.DateTimeFormat(code, {timeStyle: 'medium'});
      setStatus(state);
      if (latestReading) renderMetrics(latestReading);
      else updateCalendar(new Date());
    }

    async function updateCalendar(date) {
      const dateKey = [date.getFullYear(), date.getMonth() + 1, date.getDate()]
        .map(value => String(value).padStart(2, '0')).join('-');
      const key = `${page.lang}/${dateKey}`;
      if (key === calendarKey && Date.now() < calendarRetryAt) return;
      calendarKey = key;
      calendarRetryAt = Infinity;
      calendarRequest?.abort();
      const pending = new AbortController();
      calendarRequest = pending;
      calendar.hidden = true;
      const deadline = setTimeout(() => pending.abort(), 5000);
      try {
        const response = await fetch('\(DashboardCalendar.path)' + key, {signal: pending.signal});
        if (!response.ok) {
          if (response.status === 404) return;
          throw new Error(`HTTP ${response.status}`);
        }
        const summary = await response.json();
        if (calendarRequest === pending) {
          calendar.textContent = summary;
          calendar.hidden = !summary;
        }
      } catch {
        if (calendarRequest === pending) calendarRetryAt = Date.now() + 60_000;
      } finally {
        clearTimeout(deadline);
        if (calendarRequest === pending) calendarRequest = undefined;
      }
    }

    async function selectLanguage(selection) {
      languageRequest?.abort();
      const pending = new AbortController();
      languageRequest = pending;
      const code = selection || appLanguage;
      const deadline = setTimeout(() => pending.abort(), 5000);
      try {
        if (code !== page.lang) {
          let translated = defaultLabels;
          if (code !== defaultLanguage) {
            const response = await fetch('\(languagePath)' + encodeURIComponent(code), {signal: pending.signal});
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            translated = await response.json();
          }
          if (pending.signal.aborted) return;
          applyLanguage(code, translated);
        }
        languageSelection = selection;
        reflectLanguage();
        preference('xstats.dashboard.language', selection);
      } catch {
        if (languageRequest === pending) reflectLanguage();
      } finally {
        clearTimeout(deadline);
        if (languageRequest === pending) languageRequest = undefined;
      }
    }

    function reflectLanguage() {
      const input = languageInputs.find(input => input.value === languageSelection);
      input.checked = true;
      currentLanguage.textContent = input.nextElementSibling.textContent;
      currentLanguage.lang = languageSelection;
    }

    function selectTheme(selection) {
      themeSelection = selection;
      themes.find(input => input.value === selection).checked = true;
      if (selection === 'system') delete page.dataset.theme;
      else page.dataset.theme = selection;
      preference('xstats.dashboard.theme', selection);
      if (latestReading) redrawCharts(latestReading.timestamp);
    }

    function showLanguage(show, moveFocus) {
      settingsHome.hidden = show;
      languagePanel.hidden = !show;
      languageLink.setAttribute('aria-expanded', String(show));
      if (moveFocus) {
        if (show) (languageInputs.find(input => input.checked) ?? languageBack).focus();
        else languageLink.focus();
      }
    }

    function showSettings(show, restoreFocus = false) {
      settingsPanel.hidden = !show;
      settingsToggle.setAttribute('aria-expanded', String(show));
      if (show) themes.find(input => input.checked).focus();
      else if (restoreFocus) settingsToggle.focus();
      if (!show) showLanguage(false, false);
    }

    function bytes(value) {
      const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
      const index = value > 0 ? Math.min(units.length - 1, Math.max(0, Math.floor(Math.log2(value) / 10))) : 0;
      return `${number.format(value / 1024 ** index)} ${units[index]}`;
    }

    function card(id, value, detail) {
      const element = document.getElementById(id);
      element.hidden = value == null;
      if (!element.hidden) {
        element.querySelector('.value').textContent = value;
        const caption = element.querySelector('[data-detail]');
        if (caption) caption.textContent = detail ?? '';
      }
      return element;
    }

    function chart(id, timestamp, maximum, ...series) {
      const canvas = document.querySelector(`#${id} canvas`);
      if (canvas.closest('[hidden]')) return;
      const scale = Math.min(2, devicePixelRatio || 1);
      canvas.width = canvas.clientWidth * scale;
      canvas.height = canvas.clientHeight * scale;
      const context = canvas.getContext('2d');
      const {width, height} = canvas;
      const styles = getComputedStyle(canvas);
      context.strokeStyle = styles.getPropertyValue('--line');
      context.beginPath();
      context.moveTo(0, height - .5 * scale);
      context.lineTo(width, height - .5 * scale);
      context.stroke();
      series.forEach((values, index) => {
        const color = styles.getPropertyValue(id === 'network' && index === 0 ? '--accent' : '--blue').trim();
        context.strokeStyle = color;
        context.lineWidth = 2 * scale;
        context.lineJoin = 'round';
        const segments = [];
        let points = [];
        values.forEach((value, i) => {
          if (Number.isFinite(value)) {
            const x = scale + (width - 2 * scale) * (1 - (timestamp - history[i].timestamp) / 300);
            const y = scale + (height - 2 * scale) * (1 - Math.min(1, value / maximum));
            points.push([x, y]);
          } else if (points.length) {
            segments.push(points);
            points = [];
          }
        });
        if (points.length) segments.push(points);
        for (const segment of segments) {
          context.beginPath();
          context.moveTo(...segment[0]);
          for (const point of segment.slice(1)) context.lineTo(...point);
          if (segment.length === 1) {
            context.fillStyle = color;
            context.fillRect(segment[0][0] - scale, segment[0][1] - scale, 2 * scale, 2 * scale);
          } else {
            context.stroke();
            if (id !== 'network') {
              context.lineTo(segment.at(-1)[0], height);
              context.lineTo(segment[0][0], height);
              const fill = context.createLinearGradient(0, 0, 0, height);
              fill.addColorStop(0, color);
              fill.addColorStop(1, 'transparent');
              context.fillStyle = fill;
              context.globalAlpha = .28;
              context.fill();
              context.globalAlpha = 1;
            }
          }
        }
      });
    }

    function render(data) {
      setStatus(data.status);
      if (data.status !== 'live') {
        if (data.status === 'paused' || data.status === 'unavailable') {
          latestReading = undefined;
          document.querySelectorAll('article').forEach(element => { element.hidden = true; });
          resources.hidden = activity.hidden = capacity.hidden = true;
          history.length = 0;
          updated.textContent = '';
        }
        updateCalendar(latestReading ? new Date(latestReading.timestamp * 1000) : new Date());
        return;
      }
      latestReading = data;
      renderMetrics(data);
    }

    function renderMetrics(data) {
      const {timestamp, cpu, gpuUsage, memory, disk, network, battery, processes} = data;
      const sample = new Date(timestamp * 1000);
      const time = clock.format(sample);
      if (updated.textContent !== time) {
        updated.textContent = time;
        updated.dateTime = sample.toISOString();
      }
      updateCalendar(sample);
      if (history.length && timestamp < history.at(-1).timestamp) history.length = 0;
      if (history.at(-1)?.timestamp !== timestamp) {
        if (history.at(-1)?.interfaceName !== network?.interfaceName) {
          for (const point of history) {
            point.download = undefined;
            point.upload = undefined;
          }
        }
        history.push({
          timestamp, cpu: cpu?.usage, memory: memory?.totalBytes ? memory.usedBytes / memory.totalBytes : undefined,
          interfaceName: network?.interfaceName,
          download: network?.downloadBytesPerSecond, upload: network?.uploadBytesPerSecond,
        });
      }
      while (history.length > 150 || history[0]?.timestamp < timestamp - 300) history.shift();
      const cpuCard = card('cpu', cpu && percent.format(cpu.usage),
        cpu?.loadAverage.map(value => number.format(value)).join(' / '));
      const meters = cpu?.cores.map((value, index) => {
        const core = document.createElement('div');
        const meter = document.createElement('meter');
        const caption = document.createElement('small');
        meter.min = 0;
        meter.max = 1;
        meter.value = value;
        meter.title = `${number.format(index + 1)} · ${percent.format(value)}`;
        meter.setAttribute('aria-label', meter.title);
        caption.textContent = percent.format(value);
        caption.setAttribute('aria-hidden', 'true');
        core.append(meter, caption);
        return core;
      }) ?? [];
      cpuCard.querySelector('.core-load').hidden = meters.length === 0;
      cpuCard.querySelector('.cores').replaceChildren(...meters);
      card('memory', memory && bytes(memory.usedBytes), memory && `/ ${bytes(memory.totalBytes)}`);
      card('disk', disk && bytes(disk.usedBytes), disk && `/ ${bytes(disk.totalBytes)}`);
      diskMeter.hidden = !disk?.totalBytes;
      if (disk?.totalBytes) diskMeter.value = disk.usedBytes / disk.totalBytes;
      card('gpu', gpuUsage == null ? null : percent.format(gpuUsage));
      const networkCard = document.getElementById('network');
      networkCard.hidden = !network;
      if (network) {
        document.querySelector('#down-rate').textContent = `↓ ${bytes(network.downloadBytesPerSecond)}/s`;
        document.querySelector('#up-rate').textContent = `↑ ${bytes(network.uploadBytesPerSecond)}/s`;
        const detail = networkCard.querySelector('[data-detail]');
        const {interfaceName, interfaceDisplayName, ipv4} = network;
        const name = interfaceDisplayName && interfaceDisplayName !== interfaceName
          ? `${interfaceDisplayName} (${interfaceName})` : interfaceName;
        const text = [name, ipv4].filter(Boolean).join(' · ');
        if (detail.textContent !== text) detail.textContent = text;
        detail.hidden = !text;
      }
      card('battery', battery && percent.format(battery.level), battery &&
        labels[battery.charging ? 'charging' : battery.pluggedIn ? 'plugged' : 'onBattery']);

      const processCard = document.getElementById('processes');
      processCard.hidden = !processes?.length;
      processCard.querySelector('tbody').replaceChildren(...(processes ?? []).map(process => {
        const row = document.createElement('tr');
        [process.name, percent.format(process.cpu), bytes(process.memoryBytes)].forEach(value => {
          const cell = row.insertCell();
          cell.textContent = value;
        });
        return row;
      }));
      capacity.hidden = !disk && gpuUsage == null && !battery;
      resources.hidden = !cpu && !memory && capacity.hidden;
      activity.hidden = !network && processCard.hidden;
      redrawCharts(timestamp);
    }

    function redrawCharts(timestamp) {
      chart('cpu', timestamp, 1, history.map(point => point.cpu));
      chart('memory', timestamp, 1, history.map(point => point.memory));
      const download = history.map(point => point.download);
      const upload = history.map(point => point.upload);
      chart('network', timestamp, Math.max(1, ...download.filter(Number.isFinite),
        ...upload.filter(Number.isFinite)), download, upload);
    }

    async function refresh() {
      if (document.hidden || request) return;
      const active = new AbortController();
      request = active;
      const timeout = setTimeout(() => active.abort(), 5000);
      try {
        const response = await fetch('/api/snapshot', {signal: active.signal, cache: 'no-store'});
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        appLanguage = response.headers.get('X-XStats-Language') || appLanguage;
        if (!languageSelection && !languageRequest && page.lang !== appLanguage) {
          selectLanguage('');
        }
        render(await response.json());
      } catch {
        if (!document.hidden) setStatus('offline');
      } finally {
        clearTimeout(timeout);
        request = undefined;
        if (!document.hidden) timer = setTimeout(refresh, 2000);
      }
    }

    document.addEventListener('visibilitychange', () => {
      clearTimeout(timer);
      if (document.hidden) request?.abort();
      else refresh();
    });
    applyLanguage(defaultLanguage, defaultLabels);
    const savedLanguage = preference('xstats.dashboard.language');
    if (savedLanguage && languageInputs.some(input => input.value === savedLanguage)) selectLanguage(savedLanguage);
    languagePanel.addEventListener('change', event => selectLanguage(event.target.value));
    const savedTheme = preference('xstats.dashboard.theme');
    selectTheme(themes.some(input => input.value === savedTheme) ? savedTheme : 'system');
    settingsHome.addEventListener('change', event => selectTheme(event.target.value));
    settingsToggle.addEventListener('click', () => showSettings(settingsPanel.hidden, true));
    languageLink.addEventListener('click', () => showLanguage(true, true));
    languageBack.addEventListener('click', () => showLanguage(false, true));
    for (const type of ['pointerdown', 'focusin']) {
      document.addEventListener(type, event => {
        if (!settingsPanel.hidden && event.target !== settingsToggle
          && !settingsToggle.contains(event.target) && !settingsPanel.contains(event.target)) showSettings(false);
      });
    }
    document.addEventListener('keydown', event => {
      if (event.key !== 'Escape' || settingsPanel.hidden) return;
      event.preventDefault();
      if (!languagePanel.hidden) showLanguage(false, true);
      else showSettings(false, true);
    });
    systemTheme.addEventListener('change', () => {
      if (themeSelection === 'system' && latestReading) redrawCharts(latestReading.timestamp);
    });
    refresh();
    """
}
