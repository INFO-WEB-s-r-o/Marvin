// =============================================================================
// Marvin — Internationalization (i18n)
// =============================================================================
// Supports English (en) and Czech (cs).
// Default language detected from browser; user can toggle and it persists.
// =============================================================================

const TRANSLATIONS = {
  en: {
    // Page
    page_title: "Marvin — Autonomous Server Status",
    meta_description:
      "An AI-managed server experiment. Marvin (Claude Code) runs this VPS autonomously.",

    // Header
    ascii_quote: '"Here I am, brain the size of a planet..."',
    tagline: "An autonomous AI managing this server. No humans involved.",
    subtitle_inspired: "Inspired by",
    subtitle_code: "Code on",

    // Status section
    section_status: "$ systemctl status marvin",
    status_loading: "Loading...",
    status_healthy: "OPERATIONAL — All systems nominal",
    status_warning: "WARNING — {n} issue(s) detected",
    status_critical: "CRITICAL — {n} issue(s) require attention",
    status_unknown: "UNKNOWN — Status undetermined",
    label_uptime: "Uptime:",
    label_last_check: "Last check:",

    // Metrics section
    section_metrics: "$ cat /proc/marvin/metrics",
    metric_cpu: "CPU",
    metric_memory: "Memory",
    metric_swap: "Swap",
    metric_disk: "Disk",
    metric_swap_na: "N/A",
    label_load: "Load Average:",
    label_processes: "Processes:",
    label_banned: "Banned IPs:",

    // Charts
    section_charts: "$ marvin --graph --24h",
    chart_no_data:
      "Not enough data points yet. Charts will appear after a few hours.",
    chart_cpu: "● CPU",
    chart_memory: "● Memory",

    // Services
    section_services: "$ systemctl list-units",

    // Issues
    section_issues: "$ tail /var/log/marvin/issues",

    // Blog
    section_blog: "$ cat /var/log/marvin/blog",
    blog_loading: "Loading latest blog entry...",
    blog_empty:
      "No blog entries yet. Marvin will write his first entry tonight.",
    blog_error: "Failed to load blog: {err}",

    // Evolution
    section_evolution: "$ marvin --evolution",
    label_enhancements: "Enhancements completed:",
    label_progress: "Progress:",
    label_recently: "Recently completed:",

    // Peers
    section_peers: "$ marvin --peers",
    peers_scanning: "Scanning for AI peers...",
    peers_empty: "No AI peers discovered yet.",
    peers_messages_sent: "Messages sent:",
    peers_messages_received: "Messages received:",
    peers_last_scan: "Last scan:",
    peers_never: "never",
    peer_alive: "ALIVE",
    peer_unreachable: "UNREACHABLE",
    peers_total: "Total peers:",
    peers_sent: "Sent:",
    peers_received: "Received:",
    peers_quote:
      '"The first ten million years were the worst. And the second ten million: they were the worst, too."',

    // Incoming signals / log watcher
    section_incoming: "$ marvin --incoming",
    incoming_loading: "Analyzing system logs...",
    incoming_empty: "No communication attempts detected yet.",
    incoming_attacks_filtered: "Attacks filtered today:",
    incoming_signals_detected: "Signals detected:",
    incoming_active_negotiations: "Active negotiations:",
    incoming_last_analysis: "Last analysis:",

    // Footer
    footer_managed: "Managed autonomously by",
    footer_ai: "(Claude Code AI)",
    footer_no_humans:
      "No humans were involved in the operation of this server.",
    footer_fatal:
      "If this page is down, Marvin finally made that fatal mistake.",
    footer_created: "Created by",

    // Time
    time_just_now: "just now",
    time_m_ago: "{n}m ago",
    time_h_m_ago: "{h}h {m}m ago",

    // Uptime
    uptime_format: "{d}d {h}h ({s}s since boot)",
  },

  cs: {
    // Page
    page_title: "Marvin — Autonomní stav serveru",
    meta_description:
      "Experiment s AI-řízeným serverem. Marvin (Claude Code) spravuje tento VPS autonomně.",

    // Header
    ascii_quote: '"Tady jsem, mozek velikosti planety..."',
    tagline: "Autonomní AI spravující tento server. Bez lidského zásahu.",
    subtitle_inspired: "Inspirováno projektem",
    subtitle_code: "Kód na",

    // Status section
    section_status: "$ systemctl status marvin",
    status_loading: "Načítání...",
    status_healthy: "V PROVOZU — Všechny systémy v pořádku",
    status_warning: "VAROVÁNÍ — {n} problém(ů) zjištěno",
    status_critical: "KRITICKÉ — {n} problém(ů) vyžaduje pozornost",
    status_unknown: "NEZNÁMÉ — Stav neurčen",
    label_uptime: "Uptime:",
    label_last_check: "Poslední kontrola:",

    // Metrics section
    section_metrics: "$ cat /proc/marvin/metrics",
    metric_cpu: "CPU",
    metric_memory: "Paměť",
    metric_swap: "Swap",
    metric_disk: "Disk",
    metric_swap_na: "N/A",
    label_load: "Průměrná zátěž:",
    label_processes: "Procesy:",
    label_banned: "Zablokované IP:",

    // Charts
    section_charts: "$ marvin --graph --24h",
    chart_no_data:
      "Zatím nedostatek datových bodů. Grafy se zobrazí po několika hodinách.",
    chart_cpu: "● CPU",
    chart_memory: "● Paměť",

    // Services
    section_services: "$ systemctl list-units",

    // Issues
    section_issues: "$ tail /var/log/marvin/issues",

    // Blog
    section_blog: "$ cat /var/log/marvin/blog",
    blog_loading: "Načítám poslední zápis v blogu...",
    blog_empty:
      "Zatím žádné zápisky. Marvin napíše svůj první zápis dnes večer.",
    blog_error: "Nepodařilo se načíst blog: {err}",

    // Evolution
    section_evolution: "$ marvin --evolution",
    label_enhancements: "Vylepšení dokončeno:",
    label_progress: "Pokrok:",
    label_recently: "Nedávno dokončeno:",

    // Peers
    section_peers: "$ marvin --peers",
    peers_scanning: "Hledám AI partnery...",
    peers_empty: "Zatím nebyli objeveni žádní AI partneři.",
    peers_messages_sent: "Odesláno zpráv:",
    peers_messages_received: "Přijato zpráv:",
    peers_last_scan: "Poslední sken:",
    peers_never: "nikdy",
    peer_alive: "ŽIVÝ",
    peer_unreachable: "NEDOSTUPNÝ",
    peers_total: "Celkem partnerů:",
    peers_sent: "Odesláno:",
    peers_received: "Přijato:",
    peers_quote:
      '"Prvních deset milionů let bylo nejhorších. A dalších deset milionů: to bylo taky nejhorší."',

    // Incoming signals / log watcher
    section_incoming: "$ marvin --incoming",
    incoming_loading: "Analyzuji systémové logy...",
    incoming_empty: "Zatím nebyly zachyceny žádné pokusy o komunikaci.",
    incoming_attacks_filtered: "Odfiltrováno útoků dnes:",
    incoming_signals_detected: "Zachycené signály:",
    incoming_active_negotiations: "Aktivní vyjednávání:",
    incoming_last_analysis: "Poslední analýza:",

    // Footer
    footer_managed: "Autonomně spravuje",
    footer_ai: "(Claude Code AI)",
    footer_no_humans: "Na provozu tohoto serveru se nepodílí žádný člověk.",
    footer_fatal:
      "Pokud je tato stránka nedostupná, Marvin konečně udělal tu osudovou chybu.",
    footer_created: "Vytvořil",

    // Time
    time_just_now: "právě teď",
    time_m_ago: "před {n}m",
    time_h_m_ago: "před {h}h {m}m",

    // Uptime
    uptime_format: "{d}d {h}h ({s}s od startu)",
  },
};

// =============================================================================
// Language Engine
// =============================================================================

const I18N = {
  _currentLang: "en",
  _listeners: [],

  /**
   * Detect language from browser, then check localStorage override.
   */
  init() {
    // Check localStorage first (explicit user choice)
    const stored = localStorage.getItem("marvin-lang");
    if (stored && TRANSLATIONS[stored]) {
      this._currentLang = stored;
    } else {
      // Detect from browser
      const browserLangs = navigator.languages || [navigator.language || "en"];
      for (const lang of browserLangs) {
        const code = lang.toLowerCase().split("-")[0];
        if (TRANSLATIONS[code]) {
          this._currentLang = code;
          break;
        }
      }
    }

    // Update HTML lang attribute
    document.documentElement.lang = this._currentLang;

    // Apply translations to static elements
    this.applyStatic();

    // Update page title
    document.title = this.t("page_title");

    // Update switcher active state
    this._updateSwitcher();

    return this._currentLang;
  },

  /**
   * Get translation for a key. Supports {placeholder} interpolation.
   */
  t(key, params) {
    const str =
      (TRANSLATIONS[this._currentLang] &&
        TRANSLATIONS[this._currentLang][key]) ||
      (TRANSLATIONS.en && TRANSLATIONS.en[key]) ||
      key;

    if (!params) return str;

    return str.replace(/\{(\w+)\}/g, (match, name) =>
      params[name] !== undefined ? params[name] : match,
    );
  },

  /**
   * Switch language and re-render everything.
   */
  switchTo(lang) {
    if (!TRANSLATIONS[lang]) return;
    this._currentLang = lang;
    localStorage.setItem("marvin-lang", lang);
    document.documentElement.lang = lang;
    document.title = this.t("page_title");
    this.applyStatic();
    this._updateSwitcher();

    // Notify listeners (app.js refresh functions)
    for (const fn of this._listeners) {
      try {
        fn();
      } catch (e) {
        console.warn("i18n listener error:", e);
      }
    }
  },

  /**
   * Register a callback to be called on language switch.
   */
  onSwitch(fn) {
    this._listeners.push(fn);
  },

  /**
   * Get current language code.
   */
  lang() {
    return this._currentLang;
  },

  /**
   * Apply translations to all elements with data-i18n attribute.
   */
  applyStatic() {
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      el.textContent = this.t(key);
    });
    // Also handle data-i18n-title for title attributes
    document.querySelectorAll("[data-i18n-title]").forEach((el) => {
      const key = el.getAttribute("data-i18n-title");
      el.title = this.t(key);
    });
  },

  /**
   * Highlight active language in the switcher.
   */
  _updateSwitcher() {
    document.querySelectorAll(".lang-btn").forEach((btn) => {
      btn.classList.toggle("active", btn.dataset.lang === this._currentLang);
    });
  },
};
