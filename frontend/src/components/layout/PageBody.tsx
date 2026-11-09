import type { HTMLAttributes } from "react";
import { cn } from "@/lib/cn";
import { PAGE_X } from "./pageLayout";

/** A page's content under its header: the page gutters, and room above and below. */
export function PageBody({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn(PAGE_X, "py-4 lg:py-6", className)} {...props} />;
}
