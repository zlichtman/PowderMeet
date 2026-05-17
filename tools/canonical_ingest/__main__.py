"""Allow `python -m canonical_ingest ...` to invoke the CLI."""
from canonical_ingest.cli import main
import sys

if __name__ == "__main__":
    sys.exit(main())
