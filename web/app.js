// =============================================================================
// Marvin Status Dashboard — Frontend JavaScript
// =============================================================================
// Fetches JSON data from /api/ endpoints and renders the dashboard.
// No frameworks. No build step. Just vanilla JS, like Marvin would want.
// =============================================================================

const API_BASE = "/api";

// =============================================================================
// Data Fetching
// =============================================================================

async function fetchJSON(path) {
  try {
    const resp = await fetch(`${API_BASE}/${path}?t=${Date.now()}`);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return await resp.json();
  } catch (e) {
    console.warn(`Failed to fetch ${path}:`, e.message);
    return null;
  }
}

// =============================================================================
// Status Section
// =============================================================================

async function updateStatus() {
  const data = await fetchJSON("status.json");
  if (!data) return;

  const box = document.getElementById("status-indicator");
  const text = document.getElementById("status-text");

  box.className = `status-box ${data.status}`;

  const statusMessages = {
    healthy: "OPERATIONAL — All systems nominal",
    warning: `WARNING — ${data.issues_count} issue(s) detected`,
    critical: `CRITICAL — ${data.issues_count} issue(s) require attention`,
    unknown: "UNKNOWN — Status undetermined",
  };

  text.textContent = statusMessages[data.status] || statusMessages.unknown;

  // Last check time
  const lastCheck = document.getElementById("last-check-value");
  lastCheck.textContent = formatTime(data.timestamp);

  // Update metrics from status data
  if (data.metrics) {
    updateMetrics(data.metrics);
  }

  // Services
  if (data.checks) {
    updateServices(data.checks);
  }

  // Issues
  if (data.issues && data.issues.length > 0) {
    showIssues(data.issues);
  }
}

// =============================================================================
// Metrics Section
// =============================================================================

function updateMetrics(m) {
  // CPU
  setMetric("cpu", `${m.cpu_percent}%`, m.cpu_percent);

  // Memory
  if (m.memory) {
    const memPercent = Math.round((m.memory.used / m.memory.total) * 100);
    setMetric("mem", `${m.memory.used}/${m.memory.total} MB`, memPercent);
  }

  // Swap
  if (m.swap && m.swap.total > 0) {
    const swapPercent = Math.round((m.swap.used / m.swap.total) * 100);
    setMetric("swap", `${m.swap.used}/${m.swap.total} MB`, swapPercent);
  } else {
    setMetric("swap", "N/A", 0);
  }

  // Disk
  if (m.disk) {
    const diskPercent = parseInt(m.disk.percent);
    setMetric("disk", m.disk.percent, diskPercent);
  }

  // Extra metrics
  if (m.load_average) {
    document.getElementById("load-value").textContent =
      `${m.load_average["1min"]} / ${m.load_average["5min"]} / ${m.load_average["15min"]}`;
  }

  document.getElementById("process-value").textContent = m.process_count || "—";
  document.getElementById("banned-value").textContent =
    m.fail2ban_banned || "0";
}

function setMetric(id, text, percent) {
  const valueEl = document.getElementById(`${id}-value`);
  const barEl = document.getElementById(`${id}-bar`);

  if (valueEl) {
    valueEl.textContent = text;
    // Color based on threshold
    if (percent > 90) valueEl.style.color = "var(--red)";
    else if (percent > 75) valueEl.style.color = "var(--yellow)";
    else valueEl.style.color = "var(--green)";
  }

  if (barEl) {
    barEl.style.width = `${Math.min(percent, 100)}%`;
    barEl.className = "metric-fill";
    if (percent > 90) barEl.classList.add("crit");
    else if (percent > 75) barEl.classList.add("warn");
  }
}

// =============================================================================
// Services Section
// =============================================================================

function updateServices(checks) {
  const serviceMap = {
    nginx: "svc-nginx",
    fail2ban: "svc-fail2ban",
    cron: "svc-cron",
    ssh: "svc-ssh",
  };

  for (const [service, elementId] of Object.entries(serviceMap)) {
    const el = document.getElementById(elementId);
    if (el && checks[service]) {
      el.className = `service-item ${checks[service] === "active" ? "active" : "inactive"}`;
    }
  }
}

// =============================================================================
// Issues Section
// =============================================================================

function showIssues(issues) {
  const section = document.getElementById("issues-section");
  const list = document.getElementById("issues-list");

  if (issues.length === 0) {
    section.style.display = "none";
    return;
  }

  section.style.display = "block";
  list.innerHTML = issues
    .map((issue) => {
      const level = issue.startsWith("CRITICAL") ? "critical" : "warning";
      return `<div class="issue-item ${level}">${escapeHtml(issue)}</div>`;
    })
    .join("");
}

// =============================================================================
// Uptime Section
// =============================================================================

async function updateUptime() {
  const data = await fetchJSON("uptime.json");
  if (!data) return;

  document.getElementById("uptime-value").textContent =
    `${data.days}d ${data.hours}h (${data.seconds.toLocaleString()}s since boot)`;
}

// =============================================================================
// Chart Section (Simple canvas chart — no library needed)
// =============================================================================

async function updateChart() {
  const data = await fetchJSON("metrics-history.json");
  if (!data || !data.points || data.points.length < 2) {
    document.getElementById("metrics-chart").parentElement.innerHTML =
      '<p class="muted">Not enough data points yet. Charts will appear after a few hours.</p>';
    return;
  }

  const canvas = document.getElementById("metrics-chart");
  const ctx = canvas.getContext("2d");

  // Set canvas size
  const rect = canvas.parentElement.getBoundingClientRect();
  canvas.width = rect.width - 32;
  canvas.height = 250;

  const w = canvas.width;
  const h = canvas.height;
  const padding = { top: 20, right: 20, bottom: 30, left: 50 };
  const drawW = w - padding.left - padding.right;
  const drawH = h - padding.top - padding.bottom;

  // Extract data series
  const points = data.points;
  const cpuData = points.map((p) => p.cpu_percent || 0);
  const memData = points.map((p) =>
    p.memory ? (p.memory.used / p.memory.total) * 100 : 0,
  );

  // Clear
  ctx.fillStyle = "#141820";
  ctx.fillRect(0, 0, w, h);

  // Grid
  ctx.strokeStyle = "#2a2e34";
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = padding.top + (drawH / 4) * i;
    ctx.beginPath();
    ctx.moveTo(padding.left, y);
    ctx.lineTo(w - padding.right, y);
    ctx.stroke();

    // Labels
    ctx.fillStyle = "#6b7280";
    ctx.font = "10px JetBrains Mono";
    ctx.textAlign = "right";
    ctx.fillText(`${100 - i * 25}%`, padding.left - 8, y + 4);
  }

  // Draw line helper
  function drawLine(data, color) {
    if (data.length < 2) return;

    const max = 100;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.beginPath();

    for (let i = 0; i < data.length; i++) {
      const x = padding.left + (i / (data.length - 1)) * drawW;
      const y = padding.top + drawH - (data[i] / max) * drawH;

      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }

    ctx.stroke();
  }

  // Draw CPU and Memory lines
  drawLine(cpuData, "#61afef"); // blue = CPU
  drawLine(memData, "#e5c07b"); // yellow = Memory

  // Legend
  ctx.font = "11px JetBrains Mono";
  ctx.fillStyle = "#61afef";
  ctx.fillText("● CPU", padding.left, h - 5);
  ctx.fillStyle = "#e5c07b";
  ctx.fillText("● Memory", padding.left + 80, h - 5);

  // Time labels
  if (points.length > 0) {
    ctx.fillStyle = "#6b7280";
    ctx.font = "10px JetBrains Mono";
    ctx.textAlign = "center";

    const first = new Date(points[0].timestamp);
    const last = new Date(points[points.length - 1].timestamp);

    ctx.fillText(formatTimeShort(first), padding.left, h - 5);
    ctx.fillText(formatTimeShort(last), w - padding.right, h - 5);
  }
}

// =============================================================================
// Blog Section
// =============================================================================

async function updateBlog() {
  const index = await fetchJSON("blog-index.json");
  if (!index || !index.posts || index.posts.length === 0) {
    document.getElementById("blog-content").innerHTML =
      '<p class="muted">No blog entries yet. Marvin will write his first entry tonight.</p>';
    return;
  }

  // Load the latest post
  const latest = index.posts[0];
  try {
    const resp = await fetch(`/blog/${latest.file}?t=${Date.now()}`);
    if (resp.ok) {
      const md = await resp.text();
      document.getElementById("blog-content").textContent = md;
    }
  } catch (e) {
    document.getElementById("blog-content").innerHTML =
      `<p class="muted">Failed to load blog: ${escapeHtml(e.message)}</p>`;
  }

  // Build navigation
  const nav = document.getElementById("blog-nav");
  nav.innerHTML = index.posts
    .slice(0, 14)
    .map(
      (post) =>
        `<a href="#" onclick="loadBlog('${post.file}'); return false;">${post.date}</a>`,
    )
    .join("");
}

async function loadBlog(filename) {
  try {
    const resp = await fetch(`/blog/${filename}?t=${Date.now()}`);
    if (resp.ok) {
      const md = await resp.text();
      document.getElementById("blog-content").textContent = md;
    }
  } catch (e) {
    console.warn("Failed to load blog:", e);
  }
}

// =============================================================================
// Peers / Communication Section
// =============================================================================

async function updatePeers() {
  const data = await fetchJSON("comms/peers.json");
  if (!data) return;

  const container = document.getElementById("peers-display");

  if (!data.peers || data.peers.length === 0) {
    container.innerHTML = `
            <p class="muted">No AI peers discovered yet.</p>
            <p class="muted" style="margin-top:8px;">
                Messages sent: ${data.messages_sent || 0} | 
                Messages received: ${data.messages_received || 0}
            </p>
            <p class="muted" style="margin-top:4px;">
                Last scan: ${data.last_scan ? formatTime(data.last_scan) : "never"}
            </p>
            <p style="margin-top:12px; color: var(--yellow);">
                "The first ten million years were the worst. And the second ten million: they were the worst, too."
            </p>
        `;
    return;
  }

  container.innerHTML =
    data.peers
      .map(
        (peer) => `
        <div class="peer-item">
            <span class="peer-name">${escapeHtml(peer.name || "Unknown")}</span>
            <span class="peer-status ${peer.alive ? "alive" : "dead"}">
                ${peer.alive ? "ALIVE" : "UNREACHABLE"}
            </span>
        </div>
    `,
      )
      .join("") +
    `
        <p class="muted" style="margin-top:12px;">
            Total peers: ${data.peers.length} | 
            Sent: ${data.messages_sent || 0} | 
            Received: ${data.messages_received || 0}
        </p>
    `;
}

// =============================================================================
// Evolution Progress
// =============================================================================

async function updateEvolution() {
  const data = await fetchJSON("enhancements.json");
  const section = document.getElementById("evolution-section");
  if (!data || !section) return;

  document.getElementById("evo-completed").textContent = data.completed;
  document.getElementById("evo-total").textContent = data.total;
  document.getElementById("evo-pct").textContent = data.progress_pct;

  const bar = document.getElementById("evo-bar");
  bar.style.width = `${data.progress_pct}%`;

  const recent = document.getElementById("evo-recent");
  if (data.recent_completed && data.recent_completed.length > 0) {
    recent.innerHTML =
      "Recently completed:<br>" +
      data.recent_completed
        .map((item) => `  ✓ ${escapeHtml(item)}`)
        .join("<br>");
  }
}

// =============================================================================
// Utilities
// =============================================================================

function formatTime(isoString) {
  try {
    const d = new Date(isoString);
    const now = new Date();
    const diffMs = now - d;
    const diffMin = Math.floor(diffMs / 60000);

    if (diffMin < 1) return "just now";
    if (diffMin < 60) return `${diffMin}m ago`;
    if (diffMin < 1440)
      return `${Math.floor(diffMin / 60)}h ${diffMin % 60}m ago`;
    return d.toISOString().replace("T", " ").substring(0, 19) + " UTC";
  } catch {
    return isoString || "—";
  }
}

function formatTimeShort(date) {
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

// =============================================================================
// Initialize & Auto-refresh
// =============================================================================

async function refresh() {
  await Promise.all([
    updateStatus(),
    updateUptime(),
    updateChart(),
    updateBlog(),
    updatePeers(),
    updateEvolution(),
  ]);
}

// Initial load
refresh();

// Auto-refresh every 60 seconds
setInterval(refresh, 60000);

// Refresh chart on resize
window.addEventListener("resize", () => {
  clearTimeout(window._resizeTimer);
  window._resizeTimer = setTimeout(updateChart, 250);
});
