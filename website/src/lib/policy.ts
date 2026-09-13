import { getLocale } from '$lib/paraglide/runtime';

export const POLICY_UPDATED = { year: 2026, month: 9, day: 13 } as const;

export function formattedPolicyUpdated(): string {
  const { year, month, day } = POLICY_UPDATED;
  return new Date(year, month - 1, day).toLocaleDateString(getLocale(), {
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });
}
