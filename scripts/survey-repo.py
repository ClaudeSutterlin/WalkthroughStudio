#!/usr/bin/env python3
"""Wrapper: the canonical survey tool lives with the producer skill so the skill folder is self-contained."""
import os, runpy, sys
sys.argv[0] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".claude", "skills", "onboarding-research", "scripts", "survey_repo.py")
runpy.run_path(sys.argv[0], run_name="__main__")
