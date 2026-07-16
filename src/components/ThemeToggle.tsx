import { useEffect, useState } from "react";
import { Moon, Sun } from "lucide-react";

type Theme = "dark" | "light";

function applyTheme(t: Theme) {
  const root = document.documentElement;
  root.classList.toggle("light", t === "light");
  root.classList.toggle("dark", t === "dark");
}

export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme | null>(null);

  useEffect(() => {
    const stored = (localStorage.getItem("hme-theme") as Theme | null) ?? "dark";
    setTheme(stored);
    applyTheme(stored);
  }, []);

  function toggle() {
    const next: Theme = theme === "light" ? "dark" : "light";
    setTheme(next);
    applyTheme(next);
    try {
      localStorage.setItem("hme-theme", next);
    } catch {}
  }

  const isLight = theme === "light";

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={`Switch to ${isLight ? "dark" : "light"} theme`}
      title={`Switch to ${isLight ? "dark" : "light"} theme`}
      className="inline-flex items-center justify-center size-9 rounded-sm border border-border bg-surface hover:bg-surface-2 text-muted-foreground hover:text-foreground transition-colors"
    >
      {theme === null ? (
        <span className="size-4" />
      ) : isLight ? (
        <Sun className="size-4" />
      ) : (
        <Moon className="size-4" />
      )}
    </button>
  );
}
