import { useMutation, type DefaultError, type UseMutationOptions } from "@tanstack/react-query";
import { apiErrorMessage } from "@/api/client";

/**
 * A mutation whose failure is shown next to the form that sent it rather than
 * toasted. The message is derived from the mutation's own error, so it clears
 * the moment the next attempt starts and there is no error state to forget to
 * reset. Declaring onError is what tells the shared MutationCache that this
 * form owns its error UI.
 */
export function useFormMutation<TData = unknown, TVariables = void>({
  fallback,
  ...options
}: UseMutationOptions<TData, DefaultError, TVariables> & {
  /** What to say when the failure carries no message from the server. */
  fallback: string | ((error: unknown) => string);
}) {
  const mutation = useMutation<TData, DefaultError, TVariables>({
    ...options,
    onError: options.onError ?? (() => undefined),
  });
  const { error } = mutation;
  const errorMessage =
    error === null ? null : apiErrorMessage(error, typeof fallback === "function" ? fallback(error) : fallback);
  return { ...mutation, errorMessage };
}
