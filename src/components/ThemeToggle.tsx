import { useCallback, useEffect, useState } from "react";
import { Moon, Sun } from "lucide-react";

export type ThemePref = "light" | "dark";

const STORAGE_KEY = "hme-theme";

export function applyThemePref(pref: ThemePref) {
  const dark = pref !== "light";
  const c = document.documentElement.classList;
  c.toggle("dark", dark);
  c.toggle("light", !dark);
  document.documentElement.style.colorScheme = dark ? "dark" : "light";
}

export function ThemeToggle() {
  const [pref, setPref] = useState<ThemePref>("dark");

  useEffect(() => {
    let stored: ThemePref = "dark";
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw === "light") stored = "light";
    } catch {}
    setPref(stored);
    applyThemePref(stored);
  }, []);

  const toggle = useCallback(() => {
    setPref((cur) => {
      const next: ThemePref = cur === "dark" ? "light" : "dark";
      applyThemePref(next);
      try {
        localStorage.setItem(STORAGE_KEY, next);
      } catch {}
      return next;
    });
  }, []);

  const dark = pref === "dark";

  return (
    <button
      type="button"
      role="switch"
      aria-checked={!dark}
      aria-label={dark ? "Switch to light theme" : "Switch to dark theme"}
      title={dark ? "Switch to light theme" : "Switch to dark theme"}
      onClick={toggle}
      className="inline-flex items-center justify-center size-9 rounded-sm border border-border bg-surface text-muted-foreground transition-colors hover:text-foreground hover:bg-surface-2 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      {dark ? <Sun className="size-4" /> : <Moon className="size-4" />}
    </button>
  );
}
