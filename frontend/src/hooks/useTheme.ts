import { useCallback, useEffect, useState } from "react";

const THEMES = ["light", "dark"] as const;
export type Theme = (typeof THEMES)[number];

const THEME_KEY = "glass_theme";

function initialTheme(): Theme {
  const stored = localStorage.getItem(THEME_KEY);
  if (stored === "light" || stored === "dark") return stored;
  // Dark first: an instrument read at night. Light is the deliberate choice.
  return "dark";
}

export function useTheme() {
  const [theme, setThemeState] = useState<Theme>(initialTheme);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem(THEME_KEY, theme);
  }, [theme]);

  const toggle = useCallback(() => {
    setThemeState((current) => (current === "dark" ? "light" : "dark"));
  }, []);

  return { theme, toggle, setTheme: setThemeState };
}
