#!/bin/sh
# oracle.sh DB : the same canonical dump as logdump, produced by the sqlite3 CLI (oracle,
# /usr/bin/sqlite3 3.45.1) straight from the database. typeof() guards every column: a value of a
# kind the log field cannot carry prints BAD and can never match. f64 bits via ieee754_to_blob().
# Run it on a scratch COPY (sqlite3 may checkpoint and delete a -wal when it closes).
set -eu
db=$1
S() { echo "case typeof($1) when 'null' then 'null' when 'text' then 't:'||hex($1) else 'BAD:'||typeof($1) end"; }
B() { echo "case typeof($1) when 'null' then 'null' when 'blob' then 'b:'||hex($1) else 'BAD:'||typeof($1) end"; }
F() { echo "case when typeof($1) in ('real','integer') then 'f:'||hex(ieee754_to_blob($1)) else 'BAD:'||typeof($1) end"; }
I() { echo "case typeof($1) when 'integer' then $1 else 'BAD:'||typeof($1) end"; }
/usr/bin/sqlite3 -batch -bail "$db" <<EOF
.mode list
.headers off
select 'CXLOG001';
select 'SPACE', rowid, $(S id), $(S slug), $(S created_at) from spaces order by rowid;
select 'ENTITY', e.rowid,
  coalesce((select f.rowid from entities_fts_content f where f.c0 = e.id), 0),
  $(S e.id), $(S e.space_id), $(S e.space_slug), $(S e.entity_type), $(S e.canonical_name),
  $(S e.content), $(S e.aliases_json), $(S e.metadata_json), $(F e.confidence), $(I e.revision),
  $(I e.retracted), $(S e.valid_from), $(S e.valid_to), $(S e.created_at), $(B e.embedding)
  from entities e order by e.rowid;
select 'CLAIM', rowid, $(S id), $(S space_id), $(S space_slug), $(S subject_entity_id),
  $(S predicate), $(S object_entity_id), $(S literal_value_json), $(F confidence),
  $(S metadata_json), $(I retracted), $(S created_at) from claims order by rowid;
select 'END records=' || ((select count(*) from spaces) + (select count(*) from entities)
  + (select count(*) from claims));
EOF
