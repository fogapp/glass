import {
  Activity, Bot, Bug, ChartLine, Clock, Coins, Cpu, Database, Flame, Gauge, Globe, HardDrive, Heart, Info, Layers, Mail,
  MessageSquare, Network, Rocket, Server, Shield, ShoppingCart, Sparkles, Star, Timer, TrendingUp, TriangleAlert, Users,
  Workflow, Zap, type LucideIcon,
} from "lucide-react";
import type { HeaderIcon, HeaderSize, HeaderWidget } from "@/types";

/**
 * The icons a dashboard header may wear (`Dashboard::HEADER_ICONS`), drawn.
 * A record over the generated vocabulary, so an icon the server allows and
 * the console can't draw fails the build.
 */
export const HEADER_ICON_GLYPHS: Record<HeaderIcon, LucideIcon> = {
  activity: Activity,
  bot: Bot,
  bug: Bug,
  "chart-line": ChartLine,
  clock: Clock,
  coins: Coins,
  cpu: Cpu,
  database: Database,
  flame: Flame,
  gauge: Gauge,
  globe: Globe,
  "hard-drive": HardDrive,
  heart: Heart,
  info: Info,
  layers: Layers,
  mail: Mail,
  "message-square": MessageSquare,
  network: Network,
  rocket: Rocket,
  server: Server,
  shield: Shield,
  "shopping-cart": ShoppingCart,
  sparkles: Sparkles,
  star: Star,
  timer: Timer,
  "trending-up": TrendingUp,
  "triangle-alert": TriangleAlert,
  users: Users,
  workflow: Workflow,
  zap: Zap,
};

/**
 * A header's size: its text, the line under it, its icon, the rows it
 * starts with (`Dashboard::HEADER_ROWS`), and the fewest that show its text
 * whole — alone, and with a line under it.
 */
export const HEADER_SIZE_STYLES: Record<HeaderSize, { label: string; name: string; title: string; subtitle: string; icon: string; rows: number; fewest: [number, number] }> = {
  sm: { label: "S", name: "Small", title: "text-sm font-semibold", subtitle: "text-xs", icon: "h-4 w-4", rows: 2, fewest: [1, 2] },
  md: { label: "M", name: "Medium", title: "text-base font-semibold", subtitle: "text-xs", icon: "h-5 w-5", rows: 2, fewest: [1, 2] },
  lg: { label: "L", name: "Large", title: "text-xl font-semibold", subtitle: "text-sm", icon: "h-6 w-6", rows: 3, fewest: [1, 2] },
  xl: { label: "XL", name: "Extra large", title: "text-3xl font-semibold tracking-tight", subtitle: "text-base", icon: "h-8 w-8", rows: 3, fewest: [2, 2] },
};

/** The fewest rows a header can be without cutting its text. */
export function headerMinRows(header: Pick<HeaderWidget, "size" | "subtitle">): number {
  return HEADER_SIZE_STYLES[header.size].fewest[header.subtitle ? 1 : 0];
}
