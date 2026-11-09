import { Link, NavLink, type LinkProps, type NavLinkProps } from "react-router-dom";
import { useScopedHref } from "@/lib/scopeHref";

/** A `Link` to a scoped page that keeps the scope. */
export function ScopedLink({ to, ...props }: Omit<LinkProps, "to"> & { to: string }) {
  const href = useScopedHref();
  return <Link to={href(to)} {...props} />;
}

/** A `NavLink` (the rail) that keeps the scope. */
export function ScopedNavLink({ to, ...props }: Omit<NavLinkProps, "to"> & { to: string }) {
  const href = useScopedHref();
  return <NavLink to={href(to)} {...props} />;
}
