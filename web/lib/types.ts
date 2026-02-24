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
    memory?: { total: number; used: number };
  }>;
}

export interface PeersData {
  peers: Array<{ name: string; alive: boolean }>;
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

export interface EnhancementsData {
  completed: number;
  total: number;
  progress_pct: number;
  recent_completed: string[];
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
