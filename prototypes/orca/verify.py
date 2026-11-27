"""Synthetic replay of quote acceptance, deployment drift and publication receipts."""
import json
import sqlite3
from pathlib import Path

db = sqlite3.connect(":memory:")
db.execute("create table orders(quote text primary key)")
for _ in range(2):
    db.execute("insert into orders values (?) on conflict do nothing", ("quote-1",))
count, = db.execute("select count(*) from orders").fetchone()
merged_sha, deployed_sha = "candidate", "previous"
draft_ready, publication_receipt = True, None
result = {
    "accepted_orders": count,
    "deployment": "verified" if deployed_sha == merged_sha else "pending",
    "publication": "verified" if draft_ready and publication_receipt else "pending",
}
temp = Path("receipt.tmp")
temp.write_text(json.dumps(result))
temp.replace("receipt.json")
