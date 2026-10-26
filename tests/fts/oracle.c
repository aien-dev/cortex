/*
** Verification oracle for the Omega FTS slice (tests/fts). NOT product code.
** Links sqlite3.c from libsqlite3-sys-0.28.0 (SQLite 3.45.0), compiled with the
** same -D flags libsqlite3-sys build.rs passes (see run.sh), so FTS5, bm25,
** the unicode61 tokenizer and LIKE behave exactly as inside cortex-rs.
**
** Modes:
**   oracle plan  DB                    EXPLAIN QUERY PLAN of the cortex-rs search SQL
**   oracle dump  DB OUT                binary dump of entities_fts rows + entities (LIKE subjects)
**   oracle tok   DB OUT                unicode61 token list of every entities_fts row
**   oracle query DB QFILE OUT          run the exact cortex-rs FTS SQL for every query x space x limit
**   oracle like  DB PFILE OUT          canonical_name LIKE ?1 OR content LIKE ?1 bitmap per pattern
**   oracle log   OUT N                 glibc log() on N inputs (see flogcases below)
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "sqlite3.h"

static const char *SEARCH_SQL =
  "SELECT e.id, e.space_id, e.space_slug, e.entity_type, e.canonical_name, e.content, e.aliases_json, e.metadata_json, e.confidence, e.revision, e.retracted, e.valid_from, e.valid_to, e.created_at,\n"
  "                        COALESCE(bm25(entities_fts), 5.0) as bm25_rank\n"
  "                 FROM entities e\n"
  "                 JOIN entities_fts f ON f.id = e.id\n"
  "                 WHERE entities_fts MATCH ?1 AND e.space_slug = ?2 AND e.retracted = 0\n"
  "                 ORDER BY bm25_rank ASC\n"
  "                 LIMIT ?3";

static void die(const char *m, sqlite3 *db){
  fprintf(stderr, "oracle: %s: %s\n", m, db ? sqlite3_errmsg(db) : "");
  exit(2);
}

static sqlite3 *opendb(const char *path){
  sqlite3 *db = 0;
  if( sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, 0) ) die("open", db);
  return db;
}

static void put32(FILE *f, uint32_t v){ fwrite(&v, 4, 1, f); }
static void put64(FILE *f, uint64_t v){ fwrite(&v, 8, 1, f); }
static void putstr(FILE *f, sqlite3_stmt *st, int i){
  if( sqlite3_column_type(st, i)==SQLITE_NULL ){ put32(f, 0xFFFFFFFFu); return; }
  const unsigned char *z = sqlite3_column_text(st, i);
  int n = sqlite3_column_bytes(st, i);
  put32(f, (uint32_t)n); fwrite(z, 1, n, f);
}

static int mode_plan(const char *dbp){
  sqlite3 *db = opendb(dbp);
  const char *v[2] = { SEARCH_SQL, 0 };
  char buf[4096];
  snprintf(buf, sizeof buf, "EXPLAIN QUERY PLAN %s", SEARCH_SQL);
  sqlite3_stmt *st;
  if( sqlite3_prepare_v2(db, buf, -1, &st, 0) ) die("prepare plan", db);
  sqlite3_bind_text(st, 1, "memory", -1, SQLITE_STATIC);
  sqlite3_bind_text(st, 2, "aien-lessons", -1, SQLITE_STATIC);
  sqlite3_bind_int64(st, 3, 12);
  while( sqlite3_step(st)==SQLITE_ROW ){
    printf("%d %d %s\n", sqlite3_column_int(st,0), sqlite3_column_int(st,1),
           (const char*)sqlite3_column_text(st,3));
  }
  sqlite3_finalize(st);
  (void)v;
  printf("sqlite_version %s source_id %s\n", sqlite3_libversion(), sqlite3_sourceid());
  sqlite3_close(db);
  return 0;
}

static int mode_dump(const char *dbp, const char *out){
  sqlite3 *db = opendb(dbp);
  FILE *f = fopen(out, "wb");
  sqlite3_stmt *st;
  fwrite("FTSDUMP1", 1, 8, f);
  if( sqlite3_prepare_v2(db, "SELECT count(*) FROM entities_fts", -1, &st, 0) ) die("count", db);
  sqlite3_step(st); put32(f, (uint32_t)sqlite3_column_int64(st, 0)); sqlite3_finalize(st);
  if( sqlite3_prepare_v2(db,
      "SELECT f.rowid, f.id, f.canonical_name, f.content, f.space_slug, e.space_slug, e.retracted "
      "FROM entities_fts f LEFT JOIN entities e ON e.id = f.id ORDER BY f.rowid", -1, &st, 0) ) die("fts", db);
  while( sqlite3_step(st)==SQLITE_ROW ){
    put64(f, (uint64_t)sqlite3_column_int64(st, 0));
    putstr(f, st, 1); putstr(f, st, 2); putstr(f, st, 3); putstr(f, st, 4); putstr(f, st, 5);
    unsigned char r = sqlite3_column_type(st,6)==SQLITE_NULL ? 2 : (unsigned char)(sqlite3_column_int64(st,6)!=0);
    fwrite(&r, 1, 1, f);
  }
  sqlite3_finalize(st);
  if( sqlite3_prepare_v2(db, "SELECT count(*) FROM entities", -1, &st, 0) ) die("count2", db);
  sqlite3_step(st); put32(f, (uint32_t)sqlite3_column_int64(st, 0)); sqlite3_finalize(st);
  if( sqlite3_prepare_v2(db, "SELECT rowid, canonical_name, content FROM entities ORDER BY rowid", -1, &st, 0) ) die("ent", db);
  while( sqlite3_step(st)==SQLITE_ROW ){
    put64(f, (uint64_t)sqlite3_column_int64(st, 0));
    putstr(f, st, 1); putstr(f, st, 2);
  }
  sqlite3_finalize(st);
  fclose(f);
  sqlite3_close(db);
  return 0;
}

/* ---- tokenizer via the fts5_api (the exact unicode61 code linked into SQLite) ---- */
static fts5_api *get_api(sqlite3 *db){
  fts5_api *p = 0;
  sqlite3_stmt *st;
  if( sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &st, 0) ) die("fts5()", db);
  sqlite3_bind_pointer(st, 1, (void*)&p, "fts5_api_ptr", 0);
  sqlite3_step(st);
  sqlite3_finalize(st);
  if( !p ) die("no fts5 api", db);
  return p;
}
static FILE *gTokOut;
static int tokcb(void *ctx, int tflags, const char *pTok, int nTok, int s, int e){
  (void)ctx; (void)tflags;
  fprintf(gTokOut, " %d:%d:", s, e);
  if( nTok>32768 ) nTok = 32768;   /* FTS5_MAX_TOKEN_SIZE: what the index and queries keep */
  for(int i=0;i<nTok;i++) fprintf(gTokOut, "%02x", (unsigned char)pTok[i]);
  return SQLITE_OK;
}
static int mode_tok(const char *dbp, const char *out){
  sqlite3 *db = opendb(dbp);
  fts5_api *api = get_api(db);
  void *ud; fts5_tokenizer tk; Fts5Tokenizer *t = 0;
  if( api->xFindTokenizer(api, "unicode61", &ud, &tk) ) die("find tok", db);
  if( tk.xCreate(ud, 0, 0, &t) ) die("create tok", db);
  gTokOut = fopen(out, "wb");
  sqlite3_stmt *st;
  if( sqlite3_prepare_v2(db, "SELECT rowid, canonical_name, content FROM entities_fts ORDER BY rowid", -1, &st, 0) ) die("tok sel", db);
  while( sqlite3_step(st)==SQLITE_ROW ){
    for(int c=1;c<=2;c++){
      const char *z = (const char*)sqlite3_column_text(st, c);
      int n = sqlite3_column_bytes(st, c);
      fprintf(gTokOut, "%lld c%d", (long long)sqlite3_column_int64(st,0), c);
      if( z ) tk.xTokenize(t, 0, FTS5_TOKENIZE_DOCUMENT, z, n, tokcb);
      fprintf(gTokOut, "\n");
    }
  }
  sqlite3_finalize(st);
  /* docsize cross-check: sum of tokens recorded by fts5 itself */
  tk.xDelete(t);
  fclose(gTokOut);
  sqlite3_close(db);
  return 0;
}

/* copy SRC to DST, then replay cortex-rs style FTS updates on DST: for FTS row number i (rowid
** order) with i%3==0 "DELETE FROM entities_fts WHERE id=?" and, when also i%2==0, re-INSERT the
** same values (new rowid). Writes "D i" / "P i rowid" lines to OPS. */
static int mode_mutate(const char *src, const char *dst, const char *ops){
  sqlite3 *s = opendb(src), *d = 0;
  if( sqlite3_open(dst, &d) ) die("open dst", d);
  sqlite3_backup *b = sqlite3_backup_init(d, "main", s, "main");
  if( !b ) die("backup", d);
  sqlite3_backup_step(b, -1); sqlite3_backup_finish(b);
  sqlite3_close(s);
  FILE *o = fopen(ops, "wb");
  sqlite3_stmt *sel, *del, *ins;
  if( sqlite3_prepare_v2(d, "SELECT id, canonical_name, content, space_slug FROM entities_fts ORDER BY rowid", -1, &sel, 0) ) die("sel", d);
  if( sqlite3_prepare_v2(d, "DELETE FROM entities_fts WHERE id = ?1", -1, &del, 0) ) die("del", d);
  if( sqlite3_prepare_v2(d, "INSERT INTO entities_fts (id, canonical_name, content, space_slug) VALUES (?1, ?2, ?3, ?4)", -1, &ins, 0) ) die("ins", d);
  int n = 0, cap = 8192;
  char **v = malloc(sizeof(char*)*4*cap); int *ln = malloc(sizeof(int)*4*cap);
  while( sqlite3_step(sel)==SQLITE_ROW ){
    for(int c=0;c<4;c++){ int k = sqlite3_column_bytes(sel,c); v[n*4+c] = malloc(k+1); memcpy(v[n*4+c], sqlite3_column_text(sel,c), k); ln[n*4+c] = k; }
    n++;
  }
  sqlite3_finalize(sel);
  sqlite3_exec(d, "BEGIN", 0, 0, 0);
  for(int i=0;i<n;i++){
    if( i%3 ) continue;
    sqlite3_reset(del); sqlite3_bind_text(del, 1, v[i*4], ln[i*4], SQLITE_STATIC);
    if( sqlite3_step(del)!=SQLITE_DONE ) die("del step", d);
    fprintf(o, "D %d\n", i);
    if( i%2 ) continue;
    sqlite3_reset(ins);
    for(int c=0;c<4;c++) sqlite3_bind_text(ins, c+1, v[i*4+c], ln[i*4+c], SQLITE_STATIC);
    if( sqlite3_step(ins)!=SQLITE_DONE ) die("ins step", d);
    fprintf(o, "P %d %lld\n", i, (long long)sqlite3_last_insert_rowid(d));
  }
  sqlite3_exec(d, "COMMIT", 0, 0, 0);
  sqlite3_finalize(del); sqlite3_finalize(ins);
  sqlite3_close(d); fclose(o);
  return 0;
}

/* tokenize arbitrary byte records (u32 len + bytes) from a file; same output format, rowid = record index */
static unsigned char *slurp(const char *p, long *pn);
static int mode_tokf(const char *in, const char *out){
  sqlite3 *db; if( sqlite3_open(":memory:", &db) ) die("mem", db);
  fts5_api *api = get_api(db);
  void *ud; fts5_tokenizer tk; Fts5Tokenizer *t = 0;
  if( api->xFindTokenizer(api, "unicode61", &ud, &tk) ) die("find tok", db);
  if( tk.xCreate(ud, 0, 0, &t) ) die("create tok", db);
  long n; unsigned char *b = slurp(in, &n);
  gTokOut = fopen(out, "wb");
  long p = 0; long r = 0;
  while( p + 4 <= n ){
    uint32_t len; memcpy(&len, b+p, 4); p += 4;
    fprintf(gTokOut, "%ld c2", r);
    tk.xTokenize(t, 0, FTS5_TOKENIZE_DOCUMENT, (const char*)b+p, (int)len, tokcb);
    fprintf(gTokOut, "\n");
    p += len; r++;
  }
  fclose(gTokOut);
  return 0;
}

/* ---- query / like input: records of u32 len + bytes ---- */
static unsigned char *slurp(const char *p, long *pn){
  FILE *f = fopen(p, "rb"); if(!f){ perror(p); exit(2); }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  unsigned char *b = malloc(n+1); if( fread(b,1,n,f)!=(size_t)n ) exit(2); fclose(f);
  *pn = n; return b;
}

static int mode_query(const char *dbp, const char *qf, const char *out){
  sqlite3 *db = opendb(dbp);
  long n; unsigned char *b = slurp(qf, &n);
  FILE *o = fopen(out, "wb");
  sqlite3_stmt *st;
  char sql[4096];
  snprintf(sql, sizeof sql, "%s", SEARCH_SQL);
  /* append f.rowid is NOT done: we map e.id -> fts rowid through a second lookup so the
  ** SQL text (and plan) is byte-identical to cortex-rs. */
  if( sqlite3_prepare_v2(db, sql, -1, &st, 0) ) die("prepare search", db);
  sqlite3_stmt *rid;
  if( sqlite3_prepare_v2(db, "SELECT rowid FROM entities_fts WHERE id = ?1", -1, &rid, 0) ) die("prep rid", db);
  static const char *spaces[] = { "aien-lessons", "aien-sources", "atlas-memory", "survey-test-mask", "nope" };
  static const int limits[] = { 1, 5, 12, 50 };
  long p = 0; int qi = 0;
  while( p + 4 <= n ){
    uint32_t len; memcpy(&len, b+p, 4); p += 4;
    for(int s=0;s<5;s++) for(int l=0;l<4;l++){
      sqlite3_reset(st);
      sqlite3_bind_text(st, 1, (const char*)b+p, (int)len, SQLITE_TRANSIENT);
      sqlite3_bind_text(st, 2, spaces[s], -1, SQLITE_STATIC);
      sqlite3_bind_int64(st, 3, limits[l]);
      fprintf(o, "q%d s%d l%d", qi, s, limits[l]);
      int rc, cnt = 0;
      char line[200000]; int lp = 0;
      while( (rc = sqlite3_step(st))==SQLITE_ROW ){
        double d = sqlite3_column_double(st, 14);
        uint64_t bits; memcpy(&bits, &d, 8);
        sqlite3_reset(rid);
        sqlite3_bind_text(rid, 1, (const char*)sqlite3_column_text(st,0), sqlite3_column_bytes(st,0), SQLITE_TRANSIENT);
        long long r = -1;
        if( sqlite3_step(rid)==SQLITE_ROW ) r = sqlite3_column_int64(rid, 0);
        if( lp < 190000 ) lp += snprintf(line+lp, sizeof(line)-lp, " %lld:%016llx", r, (unsigned long long)bits);
        cnt++;
      }
      line[lp] = 0;
      fprintf(o, " %s n=%d%s\n", rc==SQLITE_DONE ? "ok" : "err", cnt, line);
    }
    p += len; qi++;
  }
  fclose(o);
  sqlite3_finalize(st); sqlite3_finalize(rid);
  sqlite3_close(db);
  return 0;
}

static int mode_like(const char *dbp, const char *pf, const char *out){
  sqlite3 *db = opendb(dbp);
  long n; unsigned char *b = slurp(pf, &n);
  FILE *o = fopen(out, "wb");
  sqlite3_stmt *cntst, *st;
  if( sqlite3_prepare_v2(db, "SELECT count(*) FROM entities", -1, &cntst, 0) ) die("c", db);
  sqlite3_step(cntst); int nent = sqlite3_column_int(cntst, 0); sqlite3_finalize(cntst);
  /* rowid -> index map */
  sqlite3_stmt *rs; long long *rows = malloc(sizeof(long long)*nent); int k = 0;
  sqlite3_prepare_v2(db, "SELECT rowid FROM entities ORDER BY rowid", -1, &rs, 0);
  while( sqlite3_step(rs)==SQLITE_ROW ) rows[k++] = sqlite3_column_int64(rs, 0);
  sqlite3_finalize(rs);
  if( sqlite3_prepare_v2(db, "SELECT rowid FROM entities WHERE canonical_name LIKE ?1 OR content LIKE ?1 ORDER BY rowid", -1, &st, 0) ) die("like", db);
  unsigned char *bm = malloc((nent+7)/8);
  long p = 0; int pi = 0;
  while( p + 4 <= n ){
    uint32_t len; memcpy(&len, b+p, 4); p += 4;
    sqlite3_reset(st);
    sqlite3_bind_text(st, 1, (const char*)b+p, (int)len, SQLITE_TRANSIENT);
    memset(bm, 0, (nent+7)/8);
    int rc, cnt = 0, j = 0;
    while( (rc = sqlite3_step(st))==SQLITE_ROW ){
      long long r = sqlite3_column_int64(st, 0);
      while( j<nent && rows[j]<r ) j++;
      if( j<nent && rows[j]==r ){ bm[j>>3] |= (unsigned char)(1<<(j&7)); }
      cnt++;
    }
    fprintf(o, "p%d %s n=%d ", pi, rc==SQLITE_DONE ? "ok" : "err", cnt);
    for(int i=0;i<(nent+7)/8;i++) fprintf(o, "%02x", bm[i]);
    fprintf(o, "\n");
    p += len; pi++;
  }
  fclose(o);
  sqlite3_finalize(st);
  sqlite3_close(db);
  return 0;
}

/* glibc log over: every IDF argument for nRow in [lo,hi] (all nHit), then random bit
** patterns, normals, [0.5,2), subnormals and near-1 values up to `target` cases, then
** special values. Output: binary f64 input, f64 output, repeated. */
static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint64_t xr(void){ rng ^= rng<<13; rng ^= rng>>7; rng ^= rng<<17; return rng; }
static int mode_log(const char *out, long target, long lo, long hi){
  FILE *o = fopen(out, "wb");
  long cnt = 0;
  for(long nRow=lo; nRow<=hi; nRow++){
    for(long nHit=0; nHit<=nRow; nHit++){
      double x = ((double)(nRow - nHit) + 0.5) / ((double)nHit + 0.5);
      double y = log(x);
      fwrite(&x, 8, 1, o); fwrite(&y, 8, 1, o); cnt++;
    }
  }
  long base = cnt;
  while( cnt < base + target ){
    uint64_t u = xr();
    double x;
    switch( cnt % 4 ){
      case 0: memcpy(&x, &u, 8); break;                                     /* any pattern */
      case 1: u = (u & 0x000FFFFFFFFFFFFFull) | 0x3FE0000000000000ull | ((u>>52)&1ull)<<52; memcpy(&x,&u,8); break; /* [0.5,2) */
      case 2: u = (u & 0x000FFFFFFFFFFFFFull) | ((uint64_t)(1 + (u>>53)%2046) << 52); memcpy(&x,&u,8); break; /* positive normal */
      default: u = (u & 0x000FFFFFFFFFFFFFull) | (((u>>52)&1ull)<<63) ; if( (cnt/4)%3==0 ) u = 0x3FF0000000000000ull + (int64_t)((int)(u%20001) - 10000); memcpy(&x,&u,8); break; /* subnormal / near 1 */
    }
    double y = log(x);
    fwrite(&x, 8, 1, o); fwrite(&y, 8, 1, o); cnt++;
  }
  /* specials */
  double sp[] = { 0.0, -0.0, 1.0, -1.0, INFINITY, -INFINITY, NAN, -NAN, 4.9406564584124654e-324, 1.7976931348623157e308 };
  for(int i=0;i<10;i++){ double y = log(sp[i]); fwrite(&sp[i],8,1,o); fwrite(&y,8,1,o); cnt++; }
  fclose(o);
  fprintf(stderr, "log cases %ld\n", cnt);
  return 0;
}

/* hardware fma reference for the Omega soft-fma: input u64 a,b,c -> fma bits */
static int mode_fma(const char *out, long target){
  FILE *o = fopen(out, "wb");
  for(long i=0;i<target;i++){
    uint64_t ua = xr(), ub = xr(), uc = xr();
    switch( i % 5 ){
      case 0: break;
      case 1: ua = (ua & 0x800FFFFFFFFFFFFFull) | ((uint64_t)(900 + ua%200) << 52);
              ub = (ub & 0x800FFFFFFFFFFFFFull) | ((uint64_t)(900 + ub%200) << 52);
              uc = (uc & 0x800FFFFFFFFFFFFFull) | ((uint64_t)(800 + uc%400) << 52); break;
      case 2: ub = (ub & 0x800FFFFFFFFFFFFFull) | ((uint64_t)(1023 - (ub%60)) << 52);
              ua = (ua & 0x800FFFFFFFFFFFFFull) | ((uint64_t)(1023 - (ua%3)) << 52);
              { double a,b,c; memcpy(&a,&ua,8); memcpy(&b,&ub,8); c = -(a*b); memcpy(&uc,&c,8); uc ^= (xr()&3); } break; /* cancellation */
      case 3: ua = (ua & 0x000FFFFFFFFFFFFFull) | ((uint64_t)(ua%3) << 52);
              ub = (ub & 0x800FFFFFFFFFFFFFull) | ((uint64_t)(1023 + ub%40) << 52);
              uc = (uc & 0x800FFFFFFFFFFFFFull) | ((uint64_t)(uc%5) << 52); break; /* subnormal region */
      default: ua = (ua & 0x000FFFFFFFFFFFFFull) | ((uint64_t)(1023 - ua%20) << 52);
               ub = (ub & 0x000FFFFFFFFFFFFFull) | ((uint64_t)(1023 - ub%20) << 52);
               uc = (uc & 0x000FFFFFFFFFFFFFull) | ((uint64_t)(1023 - uc%20) << 52); break; /* bm25-like positive */
    }
    double a,b,c,r; memcpy(&a,&ua,8); memcpy(&b,&ub,8); memcpy(&c,&uc,8);
    r = fma(a,b,c);
    fwrite(&a,8,1,o); fwrite(&b,8,1,o); fwrite(&c,8,1,o); fwrite(&r,8,1,o);
  }
  fclose(o);
  return 0;
}

int main(int argc, char **argv){
  if( argc>=3 && !strcmp(argv[1],"plan") ) return mode_plan(argv[2]);
  if( argc>=4 && !strcmp(argv[1],"dump") ) return mode_dump(argv[2], argv[3]);
  if( argc>=5 && !strcmp(argv[1],"mutate") ) return mode_mutate(argv[2], argv[3], argv[4]);
  if( argc>=4 && !strcmp(argv[1],"tokf") ) return mode_tokf(argv[2], argv[3]);
  if( argc>=4 && !strcmp(argv[1],"tok") ) return mode_tok(argv[2], argv[3]);
  if( argc>=5 && !strcmp(argv[1],"query") ) return mode_query(argv[2], argv[3], argv[4]);
  if( argc>=5 && !strcmp(argv[1],"like") ) return mode_like(argv[2], argv[3], argv[4]);
  if( argc>=6 && !strcmp(argv[1],"log") ) return mode_log(argv[2], atol(argv[3]), atol(argv[4]), atol(argv[5]));
  if( argc>=4 && !strcmp(argv[1],"fma") ) return mode_fma(argv[2], atol(argv[3]));
  fprintf(stderr, "usage: oracle plan|dump|tok|query|like|log|fma ...\n");
  return 2;
}
