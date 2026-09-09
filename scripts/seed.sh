#!/usr/bin/env bash
# Demo data. Terraform does not own data, which is why this is a shell script and
# not a resource.
#
# Burn day is two applies with this in between: an online archive cannot be
# created until its collection exists.
#
# Usage:
#   MONGODB_URI='mongodb+srv://<user>:<pass>@<host>/' scripts/seed.sh
#
# The credentials come from the workspace outputs:
#   terraform output -json superuser_passwords
set -euo pipefail

: "${MONGODB_URI:?set MONGODB_URI to the cluster connection string}"

# TODO(adrian): the real seed. Shape it needs, at minimum, for the online archive
# to have something to archive: a collection with a date field named created_at.
mongosh "$MONGODB_URI" --quiet --eval '
  db = db.getSiblingDB("analytics");
  db.events.insertMany(
    Array.from({length: 1000}, (_, i) => ({
      created_at: new Date(Date.now() - i * 86400000),
      kind: "demo",
      n: i
    }))
  );
  print("events: " + db.events.countDocuments());
'
