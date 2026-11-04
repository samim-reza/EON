import { startTransition, type FormEvent } from "react";

/**
 * React resets a form once its action finishes, so a rejected username or a mistyped password
 * would otherwise wipe everything the person entered. Pair with `action={action}`: running the
 * action from here skips that reset, and without JavaScript the form still posts normally.
 */
export function keepInputs(action: (data: FormData) => void) {
  return (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    startTransition(() => action(data));
  };
}
