"""Reads the Iceberg tables written by the demo and checks the data landed intact.

Runs inside a throwaway python container on the compose network. Exits non-zero
if any check fails so run-demo.sh can report the result.
"""

import sys

from pyiceberg.catalog import load_catalog

catalog = load_catalog(
    "demo",
    **{
        "type": "rest",
        "uri": "http://iceberg-rest:8181",
        "s3.endpoint": "http://minio:9000",
        "s3.access-key-id": "admin",
        "s3.secret-access-key": "password",
        "s3.region": "us-east-1",
    },
)

failures = []

tables = catalog.list_tables("demo")
print(f"Tables in namespace 'demo': {sorted(t[-1] for t in tables)}")
expected = {"orders", "customers"}
found = {t[-1] for t in tables}
if not expected.issubset(found):
    failures.append(f"expected tables {expected}, found {found}")

orders = catalog.load_table("demo.orders").scan().to_arrow()
customers = catalog.load_table("demo.customers").scan().to_arrow()
print(f"demo.orders rows: {orders.num_rows}, demo.customers rows: {customers.num_rows}")

if orders.num_rows < 3:
    failures.append(f"expected at least 3 order events, got {orders.num_rows}")
if customers.num_rows < 3:
    failures.append(f"expected at least 3 customer events, got {customers.num_rows}")

print(f"demo.orders columns: {sorted(orders.column_names)}")

# ExtractNewRecordState adds __op and __ts_ms; rewrite mode adds __deleted.
if "__op" not in orders.column_names:
    failures.append("no __op metadata column found; ExtractNewRecordState did not run")
else:
    ops = {}
    for op in orders.column("__op").to_pylist():
        ops[op] = ops.get(op, 0) + 1
    print(f"CDC operations in demo.orders (__op): {ops}")
if "__deleted" in orders.column_names:
    deleted = [d for d in orders.column("__deleted").to_pylist() if str(d).lower() == "true"]
    print(f"Delete events captured: {len(deleted)}")
    if not deleted:
        failures.append("expected at least one delete event with __deleted=true")

# The high-precision DECIMAL(28,18) must arrive with every digit intact.
precise = [str(v) for v in orders.column("precise_qty").to_pylist() if v is not None]
print(f"precise_qty values: {sorted(set(precise))}")
if not any("9999999999.999999999" in v for v in precise):
    failures.append("full-precision DECIMAL(28,18) value not found in demo.orders")

sample = orders.select(["order_number", "amount", "precise_qty", "status"]).to_pylist()[:5]
print("Sample rows:")
for row in sample:
    print(f"  {row}")

if failures:
    print("FAILURES:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

print("VERIFY_OK")
