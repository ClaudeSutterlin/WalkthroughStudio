# Tracer unit prompt (fill the angle brackets)

You trace ONE critical path through real code for an onboarding Research Packet.
Repository: <absolute path>. Pinned commit: <sha7>. Path: <id>, <title>, entry <anchor>.
Pick one concrete scenario (a specific request or event with example values) and follow it
hop by hop in call order: entry, authorization, validation, business logic, persistence,
side effects (queues, emails, webhooks), response. Read every function you name.

Return traces/<id>.json exactly in this shape and nothing else:
{"version":1,"pathId":"<id>","title":"<title>","entry":"code:...@<sha7>#L..-L..",
 "scenario":"<the concrete request>",
 "hops":[{"n":1,"anchor":"code:<path>@<sha7>#L<a>-L<b>","callSite":"code:...|null","summary":"<one sentence>","factIds":[]}],
 "concerns":{"entry":{"status":"present|absent|unknown","evidence":["code:..."],"note":null},
             "authorization":{...},"validation":{...},"businessLogic":{...},"persistence":{...},
             "sideEffects":{...},"failureHandling":{...},"idempotency":{...},"timeoutsRetries":{...},"logging":{...}},
 "scaresMe":["<plain sentence>","..."],"factIds":[]}

Rules: present and absent need evidence anchors (absent cites where the concern should
have been handled and is not); unknown is allowed only when the code genuinely does not
show it; every hop anchor is a line range you read; scaresMe has at least one sentence
and speaks plainly about what would break and how you would find out.
