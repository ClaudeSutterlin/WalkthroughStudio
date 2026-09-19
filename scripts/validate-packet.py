#!/usr/bin/env python3
"""Wrapper: the canonical validator lives with the producer skill so the skill folder is self-contained."""
import os, runpy, sys
sys.argv[0] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".claude", "skills", "onboarding-research", "scripts", "validate_packet.py")
runpy.run_path(sys.argv[0], run_name="__main__")
