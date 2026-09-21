# Golden projection of the fixture packet

What `.claude/skills/onboarding-research/scripts/project_packet.py` produces from
`../fixture-repo.packet`, checked in so the Swift projectors can be held to the
same output. `projectorParityProbe` runs the Swift projectors over the same packet
and diffs against these files; a difference is a failure, not a surprise.

Derived files are deliberately absent: every `docs/*.html` except one sample
(`tech-debt.html`, which covers the markdown converter) and the whole `code/`
tree, which is a verbatim copy of repository files at the pinned commit.

Regenerate after an intentional projector change, and say in the build log why the
output moved:

    python3 .claude/skills/onboarding-research/scripts/project_packet.py \
      --packet Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.packet \
      --out /tmp/golden --repo /tmp/fixture-repo
