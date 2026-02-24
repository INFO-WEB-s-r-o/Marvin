'use client';

import TerminalHeader from './components/TerminalHeader';
import AsciiHeader from './components/AsciiHeader';
import StatusSection from './components/StatusSection';
import MetricsSection from './components/MetricsSection';
import ChartSection from './components/ChartSection';
import ServicesSection from './components/ServicesSection';
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
        <MetricsSection />
        <ChartSection />
        <ServicesSection />
        <BlogSection />
        <EvolutionSection />
        <PeersSection />
        <IncomingSection />
        <Footer />
      </div>
    </div>
  );
}
