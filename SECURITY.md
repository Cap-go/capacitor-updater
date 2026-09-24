# Security

Thanks for helping keep Capgo and `@capgo/capacitor-updater` safe.

## Report a vulnerability for this repository

Do not use Discord, GitHub Issues, or any public forum.

Open a private advisory here:
https://github.com/Cap-go/capacitor-updater/security/advisories/new

Before you file, use the Capgo advisory checklist:
https://github.com/Cap-go/.github/blob/main/ADVISORY_TEMPLATE.md

## Org policy (canonical)

Reporting requirements, out-of-scope rules, what happens after you report, embargo, and bounty payout gates live in the Cap-go org security policy:
https://github.com/Cap-go/.github/blob/main/SECURITY.md

Public researcher pages:
- https://capgo.app/security/
- https://capgo.app/bug-bounty/

This plugin repository is in scope for Capgo's open-source bug bounty (see the bounty page for amounts and rules).

## Quick out-of-scope reminders

Reports in these classes are closed (see org policy and https://capgo.app/security/ for the full list):

- Unauthenticated `channel_self` set, and designed no-API-key behavior for `/updates` and `/stats`
- Uploader mislabeling encryption on `external_url` bundles
- Duplicates, already-fixed-on-`main` without a new exploit path, incomplete drafts

## Bounty

Capgo pays eligible bounties only after the fix is **released** and you have **verified** the fix. Linking or opening a PR alone is not enough. See https://capgo.app/bug-bounty/.
