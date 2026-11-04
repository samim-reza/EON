## What does this change?

## Why?

Closes #

## How was it tested?

- [ ] `npm run lint && npm run typecheck`
- [ ] `npm test`
- [ ] `npm run lab -- 10 300` (if demography changed)
- [ ] `npx supabase test db` (if SQL changed)
- [ ] Checked at phone width (if visual)

## Screenshots

## Rules check

- [ ] New tables have row-level security, and new functions set `search_path = ''`
- [ ] Shipped migrations are unchanged
- [ ] No secrets, real emails or dumps are included
