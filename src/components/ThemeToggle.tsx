import { useCallback, useEffect, useState } from "react";
import { Monitor, Moon, Sun } from "lucide-react";

export type ThemePref = "light" | "dark" | "system";

const STORAGE_KEY = "hme-theme";

function systemIsDark() {
  return (
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
  );
}

export function applyThemePref(pref: ThemePref) {
  const dark = pref === "system" ? systemIsDark() : pref === "dark";
  const c = document.documentElement.classList;
  c.toggle("dark", dark);
  c.toggle("light", !dark);
  document.documentElement.style.colorScheme = dark ? "dark" : "light";
}

const OPTIONS: { value: ThemePref; label: string; Icon: typeof Sun }[] = [
  { value: "light", label: "Light", Icon: Sun },
  { value: "dark", label: "Dark", Icon: Moon },
  { value: "system", label: "System", Icon: Monitor },
];

export function ThemeToggle() {
  const [pref, setPref] = useState<ThemePref | null>(null);

  useEffect(() => {
    let stored: ThemePref = "dark";
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw === "light" || raw === "dark" || raw === "system") stored = raw;
    } catch {}
    setPref(stored);
    applyThemePref(stored);
  }, []);

  // Follow OS changes while on "system"
  useEffect(() => {
    if (pref !== "system") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => applyThemePref("system");
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [pref]);

  const choose = useCallback((next: ThemePref) => {
    setPref(next);
    applyThemePref(next);
    try {
      localStorage.setItem(STORAGE_KEY, next);
    } catch {}
  }, []);

  return (
    <div
      role="radiogroup"
      aria-label="Color theme"
      className="inline-flex items-center gap-0.5 rounded-sm border border-border bg-surface p-0.5"
    >
      {OPTIONS.map(({ value, label, Icon }) => {
        const active = pref === value;
        return (
          <button
            key={value}
            type="button"
            role="radio"
            aria-checked={active}
            aria-label={`${label} theme`}
            title={`${label} theme`}
            onClick={() => choose(value)}
            className={
              "inline-flex items-center justify-center size-8 rounded-[3px] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring " +
              (active
                ? "bg-surface-2 text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground hover:bg-surface-2/60")
            }
          >
            <Icon className="size-4" />
          </button>
        );
      })}
    </div>
  );
}
