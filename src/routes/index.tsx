import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/lib/auth";
import { useCalculationHistory } from "@/hooks/use-calculation-history";

// No head() here: the home route inherits title/description/og/twitter from
// __root.tsx, and ships no og:image so serve-time hosting can inject the
// project's social preview (explicit og:image or latest screenshot).
export const Route = createFileRoute("/")({
  component: Index,
});

function Index() {
  const [display, setDisplay] = useState("0");
  const [previous, setPrevious] = useState<string | null>(null);
  const [operation, setOperation] = useState<string | null>(null);
  const [resetNext, setResetNext] = useState(false);
  const { isAuthenticated, user, logout } = useAuth();
  const { enabled: historyEnabled, history, save, clear: clearHistory } = useCalculationHistory();

  const clear = () => {
    setDisplay("0");
    setPrevious(null);
    setOperation(null);
    setResetNext(false);
  };

  const appendDigit = (digit: string) => {
    if (resetNext) {
      setDisplay(digit);
      setResetNext(false);
      return;
    }
    if (display === "0") {
      setDisplay(digit);
    } else {
      setDisplay(display + digit);
    }
  };

  const appendDecimal = () => {
    if (resetNext) {
      setDisplay("0.");
      setResetNext(false);
      return;
    }
    if (!display.includes(".")) {
      setDisplay(display + ".");
    }
  };

  const backspace = () => {
    if (resetNext) {
      clear();
      return;
    }
    if (display.length === 1) {
      setDisplay("0");
    } else {
      setDisplay(display.slice(0, -1));
    }
  };

  const calculate = (a: number, b: number, op: string): number => {
    switch (op) {
      case "+":
        return a + b;
      case "-":
        return a - b;
      case "*":
        return a * b;
      case "/":
        return b === 0 ? 0 : a / b;
      default:
        return b;
    }
  };

  const handleOperation = (op: string) => {
    const current = parseFloat(display);
    if (previous === null || operation === null) {
      setPrevious(display);
    } else {
      const prevValue = parseFloat(previous);
      const result = calculate(prevValue, current, operation);
      setPrevious(String(result));
      setDisplay(String(result));
    }
    setOperation(op);
    setResetNext(true);
  };

  const handleEquals = () => {
    if (previous === null || operation === null) return;
    const current = parseFloat(display);
    const prevValue = parseFloat(previous);
    const result = calculate(prevValue, current, operation);
    setDisplay(String(result));
    setPrevious(null);
    setOperation(null);
    setResetNext(true);

    if (historyEnabled) {
      // Fire-and-forget: a failed write must not block the calculator. The error surfaces
      // via save.isError below rather than throwing into the click handler.
      save.mutate({ expression: `${previous} ${operation} ${current}`, result: String(result) });
    }
  };

  const btnClass =
    "h-14 text-lg font-semibold bg-green-600 hover:bg-green-700 text-white border-green-700";

  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-3 bg-background p-4">
      {isAuthenticated && (
        <div className="flex w-full max-w-xs items-center justify-between gap-2 text-sm">
          <span className="truncate text-muted-foreground">{user?.email ?? user?.name}</span>
          <Button variant="ghost" size="sm" onClick={logout}>
            Sign out
          </Button>
        </div>
      )}

      <div className="w-full max-w-xs rounded-2xl border border-border bg-card p-5 shadow-lg">
        <div className="mb-4 rounded-xl bg-muted p-4 text-right">
          <div className="text-sm text-muted-foreground h-5">
            {previous ?? ""} {operation ?? ""}
          </div>
          <div className="text-3xl font-semibold tracking-tight text-card-foreground break-all">
            {display}
          </div>
        </div>

        <div className="grid grid-cols-4 gap-2">
          <Button variant="destructive" className={btnClass} onClick={clear}>
            C
          </Button>
          <Button variant="outline" className={btnClass} onClick={backspace}>
            ⌫
          </Button>
          <Button variant="outline" className={btnClass} onClick={() => handleOperation("/")}>
            ÷
          </Button>
          <Button variant="outline" className={btnClass} onClick={() => handleOperation("*")}>
            ×
          </Button>

          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("7")}>
            7
          </Button>
          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("8")}>
            8
          </Button>
          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("9")}>
            9
          </Button>
          <Button variant="outline" className={btnClass} onClick={() => handleOperation("-")}>
            −
          </Button>

          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("4")}>
            4
          </Button>
          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("5")}>
            5
          </Button>
          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("6")}>
            6
          </Button>
          <Button variant="outline" className={btnClass} onClick={() => handleOperation("+")}>
            +
          </Button>

          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("1")}>
            1
          </Button>
          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("2")}>
            2
          </Button>
          <Button variant="secondary" className={btnClass} onClick={() => appendDigit("3")}>
            3
          </Button>
          <Button variant="default" className={`${btnClass} row-span-2`} onClick={handleEquals}>
            =
          </Button>

          <Button
            variant="secondary"
            className={`${btnClass} col-span-2`}
            onClick={() => appendDigit("0")}
          >
            0
          </Button>
          <Button variant="secondary" className={btnClass} onClick={appendDecimal}>
            .
          </Button>
        </div>
      </div>

      {historyEnabled && (
        <div className="w-full max-w-xs rounded-2xl border border-border bg-card p-4 shadow-sm">
          <h2 className="mb-2 text-sm font-semibold text-card-foreground">Recent</h2>

          {save.isError && (
            <p className="text-xs text-destructive">Couldn't save your last calculation.</p>
          )}

          {history.isPending && <p className="text-xs text-muted-foreground">Loading…</p>}

          {history.isError && (
            <p className="text-xs text-destructive">Couldn't load your history.</p>
          )}

          {history.data?.length === 0 && (
            <p className="text-xs text-muted-foreground">Nothing yet.</p>
          )}

          <ul className="space-y-1">
            {history.data?.map((row) => (
              <li key={row.id} className="flex justify-between gap-2 text-xs">
                <span className="truncate text-muted-foreground">{row.expression}</span>
                <span className="font-medium text-card-foreground">{row.result}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
