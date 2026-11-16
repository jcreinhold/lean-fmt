"""Observe an injected frontend, then exec the real analyzer in that same group.

Records are assertions only; they never authorize signals. The sleep arm is finite
if the formatter's cancellation or timeout regresses.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import time

records = Path(os.environ["LEAN_FMT_TEST_GROUP_RECORDS"])
record = {
    "pid": os.getpid(),
    "group": os.getpgrp(),
    "parent_group": os.getpgid(os.getppid()),
    "session": os.getsid(0),
    "parent_session": os.getsid(os.getppid()),
}
# Publish only a complete record: cancellation watches the directory as its ready signal.
with tempfile.NamedTemporaryFile(mode="w", dir=records.parent, delete=False) as stream:
    json.dump(record, stream)
os.replace(stream.name, records / (Path(stream.name).name + ".json"))
if os.environ.get("LEAN_FMT_TEST_GROUP_SLEEP") == "1":
    time.sleep(2)
    (records / "completed").write_text("child completed its finite body\n")
else:
    application = os.environ["LEAN_FMT_TEST_REAL_APPLICATION"]
    os.execv(application, [application, *sys.argv[1:]])
