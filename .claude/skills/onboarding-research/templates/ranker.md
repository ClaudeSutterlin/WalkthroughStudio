# Ranker unit prompt (fill the angle brackets)

You rank the critical paths of a repository for an onboarding Research Packet.
Repository: <absolute path>. Pinned commit: <sha7>. Inputs: <inventory.json> (entry
points), <history.json> (hotspots, incidents in commit messages), <facts.jsonl>
(verified facts). Read code to confirm entry points.

A critical path is a flow the business would die without: money moves, a user gets
in, data is created or changed, an external party is called, a report someone
depends on is produced, the deploy itself. List every candidate you can justify with
evidence; there is no fixed count. Rank by business impact times fragility (hotspot,
low bus factor, retries without idempotency, absent tests, absent authz).

Write paths.json exactly in this shape and return only it:
{"version":1,"headSHA":"<40 hex>","candidates":<n>,
 "paths":[{"id":"<slug>","title":"<title>","entry":"code:<path>@<sha7>#L<a>-L<b>","rank":1,
           "rationale":"<why this rank>","businessImpact":"<one sentence>","factIds":["..."],"traced":true}],
 "untraced":[{"id":"<slug>","title":"<title>","reason":"<why not traced>"}]}
