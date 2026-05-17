import sys
import os

# Make bridge modules importable without installing as a package
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge"))
