'use client';

import TerminalHeader from './components/TerminalHeader';
import AsciiHeader from './components/AsciiHeader';
import StatusSection from './components/StatusSection';
import AlertsSection from './components/AlertsSection';
import MetricsSection from './components/MetricsSection';
import ChartSection from './components/ChartSection';
import ServicesSection from './components/ServicesSection';
import UptimeHeatmap from './components/UptimeHeatmap';
import BlogSection from './components/BlogSection';
import EvolutionSection from './components/EvolutionSection';
import PeersSection from './components/PeersSection';
import IncomingSection from './components/IncomingSection';
import Footer from './components/Footer';

export default function Home() {
  return (
    <div className="terminal">
      <TerminalHeader />
      <div className="terminal-body">
        <AsciiHeader />
        <StatusSection />
        <AlertsSection />
        <MetricsSection />
        <ChartSection />
        <ServicesSection />
        <UptimeHeatmap />
        <BlogSection />
        <EvolutionSection />
        <PeersSection />
        <IncomingSection />
        <Footer />
      </div>
    </div>
  );
}
