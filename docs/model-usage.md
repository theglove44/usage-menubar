# Model usage and API-equivalent value

Click a provider card to see recorded local token usage by model. This answers
“what would these recorded tokens cost at the listed API rates?” The quota cards
still describe subscription allowance; they are a different measurement.

## Controls

- Settings saves provider enablement, menu-bar selection and runway visibility.
  Defaults preserve the existing three providers and visible runway. When the
  selected provider is disabled, the gauge uses the first enabled provider in
  Codex/Claude/Grok order. With none enabled, it says Usage and Settings remains
  accessible. Re-enabling the preferred provider restores its gauge.
- Disabling a provider stops future quota reads and, for Claude, future account
  refreshes. An existing request can finish. It does not modify accounts, local
  records or running agents. Runway visibility is a separate display preference.
- Today starts at this Mac's local midnight. 7 days and 30 days are rolling
  intervals ending at the displayed refresh time. Refresh rereads local usage;
  it does not download new prices.

## Local data and counting

`ModelUsageScanner` streams JSONL files on its actor, away from the main UI thread.
Only safe model identifiers, record identities, timestamps and token counts enter
the usage state. No message content is persisted, logged or sent over a network.
Changed files are reparsed; unchanged file results are cached in memory for the
lifetime of the dropdown, including navigation between provider details. No
database or new dependency is required. Leaving a detail screen cancels its
scan; cancelled partial reads never enter the cache.

| Provider | Files | Counting rule |
| --- | --- | --- |
| Codex | `$CODEX_HOME/sessions` and sibling `archived_sessions` (default `~/.codex`) | Model comes from `turn_context`. A changed cumulative `token_count` admits its `last_token_usage` once. Repeated totals are ignored. Older records can use a cumulative delta when a baseline exists. |
| Claude | `projects` under the existing configured Claude roots, including `~/.claude` | Assistant `message.usage`, deduplicated by message ID. Repeated streaming records use the maximum category counts. Both five-minute and one-hour cache writes are recognised. |
| Grok | `~/.grok/sessions` | `turn_completed` records, using each entry in `usage.modelUsage`. Session ID, prompt ID and model identify one turn result. The outer usage total is not added again. |

Input categories are disjoint. Codex and Grok include cached tokens inside their
input totals, so cache reads/writes are subtracted before pricing ordinary input.
Claude reports those categories separately. Reasoning tokens already form part
of output; they are not added twice. Copies of the same usage record across
configured roots or archives are deduplicated before aggregation.

Files modified in the last 31 days are streamed in full to recover earlier model
metadata and cumulative baselines. Each read is 256 KiB; individual records over
8 MiB are skipped. Unreadable files/folders, malformed JSON or oversized records
produce a partial-coverage warning. Complete final records without a newline
are accepted. Future timestamps are excluded.

Missing sources and empty periods are distinguished. Local data may omit web,
cloud or other-device use, deleted history, older unsupported log formats and
requests whose usage was never written. A file with no supported usage records
does not imply zero account usage. This feature does not derive tokens from quota
percentages, session burn rate or the current context size.

## Pricing basis

The bundled `ModelPricing` table was checked on **2026-09-05** against:

- [OpenAI API pricing](https://developers.openai.com/api/docs/pricing), standard
  short-context rates, including GPT-6 Astra and GPT-5.6 Sol/Terra/Luna.
- [GPT-5.5 pricing](https://developers.openai.com/api/docs/models/gpt-5.5).
- [Anthropic model pricing](https://platform.claude.com/docs/en/about-claude/pricing).
- [Grok 4.6 pricing](https://docs.x.ai/developers/models/grok-4.6).

Each category is multiplied by its USD price per million tokens, then summed.
The estimate uses the current bundled rates for the whole selected period,
rather than reconstructing historical prices. It excludes long-context premiums,
fast/priority premiums, batch discounts, geography uplifts, tools, tax and currency
conversion. In particular it is a standard short-context comparison even when a
local request used a larger context or faster service tier. Grok's `grok-4.6-build`
uses public Grok 4.6 pricing as an explicitly labelled equivalent, not a claim
about Build's subscription billing. Unknown model names are never fuzzy-matched
to a different model; only dated snapshot suffixes are stripped.

Model and provider cost subtotals exclude unknown prices while retaining their
tokens. If any model lacks a price the total says **priced models only**; if all
prices are unknown it says **Price unavailable**. The in-app footer always shows
the verification date and a link to the provider's official price page. Future
price changes require updating the table, date and relevant arithmetic tests,
then rebuilding. No account or payment API is used for this feature.

## Verification

Run `./scripts/test.sh --disable-sandbox`, then `./rebuild.sh`. The fixture tests
cover saved preferences, all-disabled recovery, disabled-Claude request gating,
model changes, repeated records, caching categories, counter resets, unknown
prices, time periods and malformed/changed files. Live UI checks should exercise
Settings, provider cards, period selection, refresh and Back after installation.
