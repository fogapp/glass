import { Activity, BellRing, Boxes, Compass, Flame, LayoutDashboard, LayoutGrid, ListTree, ScrollText, Settings, Stethoscope, Users, Waypoints } from "lucide-react";

/** The rail, top to bottom. `key` is the `g` + key shortcut. */
export const NAV = [
  { to: "/", label: "Overview", icon: LayoutDashboard, end: true, key: "o" },
  { to: "/triage", label: "Triage", icon: Stethoscope, end: false, key: "r" },
  { to: "/apps", label: "Apps", icon: Boxes, end: false, key: "a" },
  { to: "/explore", label: "Explore", icon: Compass, end: false, key: "e" },
  { to: "/traces", label: "Traces", icon: Waypoints, end: false, key: "t" },
  { to: "/profiles", label: "Profiles", icon: Flame, end: false, key: "p" },
  { to: "/logs", label: "Logs", icon: ScrollText, end: false, key: "l" },
  { to: "/visitors", label: "Visitors", icon: Users, end: false, key: "u" },
  { to: "/dashboards", label: "Dashboards", icon: LayoutGrid, end: false, key: "d" },
  { to: "/monitors", label: "Monitors", icon: BellRing, end: false, key: "m" },
  { to: "/fleet", label: "Fleet", icon: ListTree, end: false, key: "f" },
  { to: "/activity", label: "Activity", icon: Activity, end: false, key: "v" },
  { to: "/settings", label: "Settings", icon: Settings, end: false, key: "s" },
] as const;
