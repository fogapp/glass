import { Component, type ReactNode } from "react";
import { useLocation } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { isChunkLoadError } from "@/lib/chunkLoad";

/**
 * Contains a render crash to the page that crashed.
 *
 * api.get<T> trusts T with no runtime validation — a deliberate house rule —
 * which means one unexpected server shape reaching a render-time .toFixed()
 * or .map() throws during render. Without a boundary that white-screened the
 * entire console, nav and all; with one, the blast radius is a page and the
 * sidebar stays usable.
 *
 * Pages load lazily, so the same boundary also catches a page whose code
 * never arrived — after a deploy the old chunks are gone, and only a reload
 * (which fetches the new index) brings the page back.
 */

type Props = { children: ReactNode; resetKey: string };
type State = { error: Error | null };

class Boundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidUpdate(previous: Props) {
    // Navigating away is the natural "try something else" — reset so the
    // next page renders instead of inheriting the crash.
    if (previous.resetKey !== this.props.resetKey && this.state.error) {
      this.setState({ error: null });
    }
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;

    if (isChunkLoadError(error)) {
      return (
        <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3 p-8 text-center">
          <p className="text-sm font-medium text-foreground">This page could not be loaded.</p>
          <p className="max-w-md text-sm text-muted">
            Glass may have been updated since this tab opened. Reload to get the current version.
          </p>
          <Button variant="secondary" onClick={() => window.location.reload()}>
            Reload
          </Button>
        </div>
      );
    }

    return (
      <div className="flex min-h-[50vh] flex-col items-center justify-center gap-3 p-8 text-center">
        <p className="text-sm font-medium text-foreground">This page hit a rendering error.</p>
        <p className="max-w-md text-sm text-muted">
          {error.message || "Something unexpected happened while drawing this page."}
        </p>
        <Button variant="secondary" onClick={() => this.setState({ error: null })}>
          Try again
        </Button>
      </div>
    );
  }
}

export function RouteErrorBoundary({ children }: { children: ReactNode }) {
  const location = useLocation();
  return <Boundary resetKey={location.pathname}>{children}</Boundary>;
}
