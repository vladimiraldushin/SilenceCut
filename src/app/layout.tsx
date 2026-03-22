import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'SilenceCut — Auto Silence Removal',
  description: 'Web-based video editor that automatically detects and removes silence from your videos',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className="bg-zinc-950 text-zinc-100 min-h-screen">{children}</body>
    </html>
  );
}
