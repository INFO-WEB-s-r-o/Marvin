export interface StatusData {
  status: 'healthy' | 'warning' | 'critical' | 'unknown';
  timestamp: string;
  issues_count: number;
  metrics?: MetricsData;
  checks?: Record<string, string>;
  issues?: string[];
}

export interface MetricsData {
  cpu_percent: number;
  memory: { total: number; used: number; free: number; available: number };
  swap: { total: number; used: number; free: number };
  disk: { total: number; used: number; available: number; percent: string };
  load_average: { '1min': number; '5min': number; '15min': number };
  process_count: number;
  fail2ban_banned: number;
}

export interface UptimeData {
  days: number;
  hours: number;
  seconds: number;
}

export interface MetricsHistory {
  points: Array<{
    timestamp: string;
    cpu_percent: number;
    memory?: { total: number; used: number; free?: number; available?: number };
    disk?: { total: number; used: number; available: number; percent: string };
    load_average?: { '1min': number; '5min': number; '15min': number };
  }>;
}

export interface PeersData {
  peers: Array<{
    name: string;
    alive: boolean;
    trust_score?: number;
    trust_breakdown?: { longevity: number; aliveness: number; beacon: number; identity: number };
    days_known?: number;
    type?: string;
  }>;
  messages_sent: number;
  messages_received: number;
  last_scan: string;
}

export interface IncomingData {
  attacks_filtered_today: number;
  signals_today: number;
  active_negotiations: number;
  last_analysis: string;
  recent_signals?: Array<{
    classification: string;
    source_ip: string;
    summary: string;
  }>;
  negotiations?: Array<{
    source_ip?: string;
    name?: string;
    status: string;
  }>;
}

export interface SlaData {
  days: Array<{ date: string; samples: number; expected: number; uptime_pct: number }>;
  summary: {
    days_tracked: number;
    total_samples: number;
    total_expected: number;
    overall_uptime_pct: number;
    worst_day: { date: string; uptime_pct: number };
    best_day: { date: string; uptime_pct: number };
    days_at_100pct: number;
  };
  generated_at: string;
}

export interface EnhancementsData {
  completed: number;
  total: number;
  progress_pct: number;
  recent_completed: string[];
}

export interface ThoughtsData {
  thoughts: Array<{
    date: string;
    text: string;
    category: 'intention' | 'observation' | 'reflection';
  }>;
  generated_at: string;
  source_count: number;
}

export interface ExternalDomainData {
  id: string;
  name: string;
  host: string;
  url: string;
  status: 'healthy' | 'warning' | 'critical' | 'failing';
  http_code: number | null;
  response_ms: number | null;
  ssl_days: number | null;
  dns: 'ok' | 'failing' | 'skipped';
}

export interface ExternalDomainsData {
  timestamp: string;
  count: number;
  domains: ExternalDomainData[];
}

export interface BlogPostData {
  id: number;
  date: string;
  type: 'morning' | 'evening';
  lang: string;
  title: string | null;
  content: string;
  excerpt: string | null;
}
