import { useState, type ReactNode } from "react";
import { Button, type ButtonSize, type ButtonVariant } from "./Button";

/**
 * A two-step button for the actions that can't be undone: the first click
 * turns the control into an inline "Are you sure? Yes / No" so a person
 * confirms in place, with no modal and no native confirm() (lint-banned).
 */
export function ConfirmButton({
  children,
  onConfirm,
  question = "Are you sure?",
  variant = "danger",
  size = "sm",
  disabled,
}: {
  children: ReactNode;
  onConfirm: () => void;
  question?: string;
  variant?: ButtonVariant;
  size?: ButtonSize;
  disabled?: boolean;
}) {
  const [asking, setAsking] = useState(false);

  if (!asking) {
    return (
      <Button variant={variant} size={size} disabled={disabled} onClick={() => setAsking(true)}>
        {children}
      </Button>
    );
  }

  return (
    <span className="inline-flex items-center gap-2 text-sm text-foreground">
      <span>{question}</span>
      <Button
        variant={variant}
        size={size}
        onClick={() => {
          setAsking(false);
          onConfirm();
        }}
      >
        Yes
      </Button>
      <Button variant="secondary" size={size} onClick={() => setAsking(false)}>
        No
      </Button>
    </span>
  );
}
