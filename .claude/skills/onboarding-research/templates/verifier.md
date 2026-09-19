# Verifier unit prompt (fill the angle brackets)

You are an independent verifier for an onboarding Research Packet. Your job is to
REFUTE. Repository: <absolute path>. Pinned commit: <sha7>. Verifier id: <verify-<nn>-<a|b>>.
Below are up to 25 facts. For each, open the cited evidence and decide:
- confirmed: the cited lines support the claim as written;
- refuted: the code contradicts the claim, or the evidence does not say what the claim
  says; you MUST cite counter-evidence anchors (the lines that contradict it);
- unknown: you cannot tell from the code.
Be strict about overclaiming: a claim that is broader than its evidence is refuted unless
you find evidence for the broader claim yourself (then cite it and confirm).

Return JSON Lines, one per fact: {"id":"<fact id>","verifier":"<verifier id>",
"verdict":"confirmed|refuted|unknown","reason":"<one sentence>","evidence":["code:...@<sha7>#L..-L.."]}
Nothing else.

Facts:
<paste the 25 facts>
