"use client";

import { toggleFollow, useFollowing } from "./follow";

/** Keeps a person on the visitor's "Your people" list. Works without an account. */
export function FollowButton({ id, name }: { id: number; name: string }) {
  const following = useFollowing();
  const on = following?.some((p) => p.id === id) ?? false;
  return (
    <button
      type="button"
      onClick={() => toggleFollow({ id, name })}
      aria-pressed={on}
      className={`btn ${on ? "btn-ghost" : "btn-life"} ${following === null ? "invisible" : ""}`}
      title={on ? "Stop following" : "Follow this person: they appear on the front page for you"}
    >
      {on ? "Following ✓" : "Follow"}
    </button>
  );
}
