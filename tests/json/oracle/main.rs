// Verification oracle for om/json.om, om/f64.om, om/uni_rust.om (not product code).
// Record framing everywhere: u32 little-endian length, then bytes.
use std::io::{Read, Write};

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 { self.0 ^= self.0 << 13; self.0 ^= self.0 >> 7; self.0 ^= self.0 << 17; self.0 }
    fn below(&mut self, n: u64) -> u64 { self.next() % n }
    fn chance(&mut self, p: u64) -> bool { self.below(1000) < p }
}

fn put(out: &mut Vec<u8>, b: &[u8]) { out.extend_from_slice(&(b.len() as u32).to_le_bytes()); out.extend_from_slice(b); }
fn records(inp: &[u8]) -> Vec<&[u8]> {
    let mut v = Vec::new(); let mut i = 0;
    while i + 4 <= inp.len() { let n = u32::from_le_bytes(inp[i..i+4].try_into().unwrap()) as usize; v.push(&inp[i+4..i+4+n]); i += 4 + n; }
    v
}

// ---------------- JSON document generator ----------------
const KEYS: &[&str] = &["a", "b", "query", "kind", "x", "", "aa", "A", "\u{e9}", "z\u{1F600}", "ab", "b\\u0061", "$serde_json::private::RawValue"];
fn ws(r: &mut Rng, o: &mut String) { if r.chance(300) { for _ in 0..r.below(3) { o.push([' ', '\n', '\t', '\r'][r.below(4) as usize]); } } }
fn gen_num(r: &mut Rng, o: &mut String) {
    match r.below(12) {
        0 => o.push_str(&r.next().to_string()),
        1 => { o.push('-'); o.push_str(&(r.next() >> r.below(64)).to_string()); }
        2 => o.push_str(["0", "-0", "0.0", "-0.0", "1e400", "-1e400", "1e-400", "18446744073709551615", "18446744073709551616", "-9223372036854775808", "-9223372036854775809", "9223372036854775808", "1.0", "1e308", "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308", "2.2250738585072014e-308", "4.9e-324", "5e-324", "2.4e-324", "2.5e-324", "1E5", "1e+5", "1e-5", "0e999999999999", "1e2147483647", "1e2147483648", "0.000001", "1e-7", "123456789012345678901234567890", "0.1", "0.2", "0.30000000000000004", "100000000000000000000000", "1e22", "1e23", "9007199254740993", "-1e-400", "0e-5"][r.below(40) as usize]),
        3..=7 => {
            if r.chance(200) { o.push('-'); }
            let lim = if r.chance(200) { 30 } else { 19 }; let nd = 1 + r.below(lim);
            for i in 0..nd { o.push((b'0' + if i == 0 { 1 + r.below(9) as u8 } else { r.below(10) as u8 }) as char); }
            if r.chance(600) { o.push('.'); let lim = if r.chance(100) { 25 } else { 10 }; for _ in 0..1 + r.below(lim) { o.push((b'0' + r.below(10) as u8) as char); } }
            if r.chance(500) { o.push(if r.chance(500) { 'e' } else { 'E' }); match r.below(3) { 0 => o.push('-'), 1 => o.push('+'), _ => {} } let e = match r.below(4) { 0 => r.below(30), 1 => r.below(330), 2 => r.below(400), _ => r.next() % 100000000000 }; o.push_str(&e.to_string()); }
        }
        8 => { o.push_str("0."); for _ in 0..r.below(20) { o.push('0'); } o.push_str(&r.next().to_string()); if r.chance(500) { o.push_str(&format!("e{}", r.below(40))); } }
        _ => { let f = f64::from_bits(r.next()); if f.is_finite() { o.push_str(&ryu::Buffer::new().format_finite(f).to_string()); } else { o.push('1'); } }
    }
}
fn gen_str(r: &mut Rng, o: &mut String) {
    o.push('"');
    let lim = if r.chance(50) { 200 } else { 12 }; let n = r.below(lim);
    for _ in 0..n {
        match r.below(20) {
            0 => o.push_str(["\\\"", "\\\\", "\\/", "\\b", "\\f", "\\n", "\\r", "\\t"][r.below(8) as usize]),
            1 => o.push_str(&format!("\\u{:04x}", r.below(0x10000))),
            2 => { let c = 0x10000 + r.below(0x100000) as u32; let c = c - 0x10000; o.push_str(&format!("\\u{:04X}\\u{:04x}", 0xD800 + (c >> 10), 0xDC00 + (c & 0x3ff))); }
            3 => o.push(['\u{e9}', '\u{3a3}', '\u{1F600}', '\u{7f}', '\u{80}', '\u{ffff}', '\u{2028}', '\u{130}', 'K'][r.below(9) as usize]),
            4 if r.chance(100) => o.push_str(["\\ud800", "\\udc00", "\\ud800x", "\\ud800\\n", "\\ud800\\ud800", "\\uZZZZ", "\\u12", "\\x"][r.below(8) as usize]),
            _ => o.push((b'a' + r.below(26) as u8) as char),
        }
    }
    o.push('"');
}
fn gen_val(r: &mut Rng, o: &mut String, d: u32) {
    ws(r, o);
    let lim = if d > 5 { 6 } else { 9 }; let k = r.below(lim);
    match k {
        0 => o.push_str("null"), 1 => o.push_str("true"), 2 => o.push_str("false"),
        3 | 4 => gen_num(r, o), 5 => gen_str(r, o),
        6 => { o.push('['); let n = r.below(5); for i in 0..n { if i > 0 { ws(r, o); o.push(','); } gen_val(r, o, d + 1); } ws(r, o); o.push(']'); }
        _ => { o.push('{'); let n = r.below(5); for i in 0..n { if i > 0 { ws(r, o); o.push(','); } ws(r, o);
                 if r.chance(100) && i == 0 { o.push_str("\"$serde_json::private::RawValue\""); ws(r, o); o.push(':'); ws(r, o); let mut inner = String::new(); gen_val(r, &mut inner, d + 1); o.push_str(&serde_json::to_string(&inner).unwrap()); continue; }
                 if r.chance(700) { o.push_str(&serde_json::to_string(KEYS[r.below(KEYS.len() as u64) as usize]).unwrap()); } else { gen_str(r, o); }
                 ws(r, o); o.push(':'); gen_val(r, o, d + 1); } ws(r, o); o.push('}'); }
    }
    ws(r, o);
}
const NASTY: &[u8] = b"\"\\,]}[{: \n\t\x00\x1f\x7f\x80\xc3\xed\xf4\xffe.-019x\r";
fn gen_doc(r: &mut Rng, i: u64) -> Vec<u8> {
    if i % 97 == 0 {
        let d = 120 + r.below(12) as usize; let mut s = String::new();
        for j in 0..d { if j % 3 == 2 { s.push_str("{\"k\":"); } else { s.push('['); } }
        if r.chance(500) { s.push('1'); for j in (0..d).rev() { s.push(if j % 3 == 2 { '}' } else { ']' }); } }
        return s.into_bytes();
    }
    if i % 89 == 0 { // raw value nesting
        let mut s = String::new(); gen_val(r, &mut s, 3);
        for _ in 0..1 + r.below(3) { s = format!("{{\"$serde_json::private::RawValue\":{}{}}}", serde_json::to_string(&s).unwrap(), if r.chance(200) { ",\"x\":1" } else { "" }); }
        return s.into_bytes();
    }
    let mut s = String::new(); gen_val(r, &mut s, 0);
    let mut b = s.into_bytes();
    match r.below(10) {
        0..=3 => {}
        4 => { let n = r.below(b.len() as u64 + 1) as usize; b.truncate(n); }
        5 | 6 => { for _ in 0..1 + r.below(2) { let p = r.below(b.len() as u64 + 1) as usize; b.insert(p, NASTY[r.below(NASTY.len() as u64) as usize]); } }
        7 => { if !b.is_empty() { let p = r.below(b.len() as u64) as usize; b[p] = NASTY[r.below(NASTY.len() as u64) as usize]; } }
        8 => { if !b.is_empty() { let p = r.below(b.len() as u64) as usize; b.remove(p); } }
        _ => { b.extend_from_slice([&b" "[..], b" x", b"1", b",", b"\n\n}", b" \t\r\n", b"{}"][r.below(7) as usize]); }
    }
    b
}

fn json_case(doc: &[u8], out: &mut Vec<u8>) {
    // A: serde_json::from_slice::<Value> (with end())
    let mut a = Vec::new();
    match serde_json::from_slice::<serde_json::Value>(doc) {
        Ok(v) => { a.push(b'O'); a.extend_from_slice(serde_json::to_string(&v).unwrap().as_bytes()); }
        Err(e) => { a.push(b'E'); a.push(match e.classify() { serde_json::error::Category::Eof => b'1', serde_json::error::Category::Syntax => b'2', serde_json::error::Category::Data => b'3', _ => b'9' }); a.extend_from_slice(e.to_string().as_bytes()); }
    }
    put(out, &a);
    // C: js_canon_buf (from_str semantics on the same bytes) then the A tree re-serialized again
    let mut c = Vec::new();
    match serde_json::from_slice::<serde_json::Value>(doc) {
        Ok(v) => { let t = serde_json::to_string(&v).unwrap(); c.push(b'O'); c.extend_from_slice(t.as_bytes()); c.push(b'|'); c.extend_from_slice(t.as_bytes()); }
        Err(_) => c.push(b'F'),
    }
    put(out, &c);
    // B: axum Json path: serde_path_to_error over Deserializer::from_slice, no end()
    let mut b = Vec::new();
    let de = &mut serde_json::Deserializer::from_slice(doc);
    match serde_path_to_error::deserialize::<_, serde_json::Value>(de) {
        Ok(v) => { b.push(b'O'); b.extend_from_slice(serde_json::to_string(&v).unwrap().as_bytes()); }
        Err(e) => { b.push(b'E'); b.push(match e.inner().classify() { serde_json::error::Category::Eof => b'1', serde_json::error::Category::Syntax => b'2', serde_json::error::Category::Data => b'3', _ => b'9' }); b.extend_from_slice(e.to_string().as_bytes()); }
    }
    put(out, &b);
}

fn f64_case(bits: u64, out: &mut Vec<u8>) {
    let f = f64::from_bits(bits);
    let mut rec = Vec::new();
    if f.is_finite() { rec.extend_from_slice(ryu::Buffer::new().format_finite(f).as_bytes()); } else { rec.extend_from_slice(b"-"); }
    rec.push(b' ');
    let z = zmij::Buffer::new().format(f).to_string();
    rec.extend_from_slice(z.as_bytes()); rec.push(b' ');
    rec.extend_from_slice(serde_json::to_string(&f).unwrap().as_bytes()); rec.push(b' ');
    // serde_json Value parse of the zmij text (non-roundtrip parser), result re-serialized + bits
    match serde_json::from_str::<serde_json::Value>(&z) {
        Ok(serde_json::Value::Number(n)) => { if let Some(x) = n.as_f64() { if n.is_f64() { rec.extend_from_slice(format!("f{:016x}", x.to_bits()).as_bytes()); } else { rec.extend_from_slice(format!("i{}", n).as_bytes()); } } }
        Ok(_) => rec.extend_from_slice(b"?"),
        Err(e) => rec.extend_from_slice(format!("E{}", e).as_bytes()),
    }
    put(out, &rec);
}

#[derive(serde::Deserialize)]
#[allow(dead_code)]
struct Q { query: String }

fn api_doc(r: &mut Rng) -> Vec<u8> {
    let mut s = String::new(); ws(r, &mut s); s.push('{');
    let n = r.below(5); let mut first = true;
    for _ in 0..n {
        if !first { ws(r, &mut s); s.push(','); } first = false; ws(r, &mut s);
        let key = if r.chance(450) { "query" } else { ["quer", "a", "queryx", "q"][r.below(4) as usize] };
        s.push_str(&format!("\"{}\"", key)); ws(r, &mut s); s.push(':');
        let mut v = String::new(); if r.chance(300) { gen_str(r, &mut v); } else { gen_val(r, &mut v, 4); }
        if serde_json::from_str::<serde_json::Value>(&v).is_err() { v = "1".into(); }
        s.push_str(&v);
    }
    ws(r, &mut s); s.push('}'); ws(r, &mut s); s.into_bytes()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut inp = Vec::new();
    let mut out = Vec::new();
    match args[1].as_str() {
        "gen-json" => { let n: u64 = args[2].parse().unwrap(); let mut r = Rng(args[3].parse().unwrap()); for i in 0..n { put(&mut out, &gen_doc(&mut r, i)); } }
        "json" => { std::io::stdin().read_to_end(&mut inp).unwrap(); for d in records(&inp) { json_case(d, &mut out); } }
        "gen-f64" => { let n: u64 = args[2].parse().unwrap(); let mut r = Rng(args[3].parse().unwrap());
            let mut edge: Vec<u64> = vec![0, 1 << 63, 1, 2, 0x000fffffffffffff, 0x0010000000000000, 0x7fefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0xfff8000000000001, 0x3ff0000000000000, 0x3fb999999999999a, 0x4340000000000000, 0x4330000000000000, 0x3eb0c6f7a0b5ed8d, 0x7e37e43c8800759c];
            for e in 0..2047u64 { edge.push(e << 52); edge.push((e << 52) | 1); edge.push((e << 52) | 0xfffffffffffff); }
            for p in -330i32..310 { for s in ["1", "2", "5", "9", "15", "123456789", "1.5", "9.999999999999999"] { if let Ok(x) = format!("{}e{}", s, p).parse::<f64>() { edge.push(x.to_bits()); } } }
            for b in &edge { out.extend_from_slice(&b.to_le_bytes()); }
            for _ in 0..n { let b = match r.below(4) { 0 => r.next(), 1 => r.next() & 0x800fffffffffffff | ((1023 + r.below(120) - 60) << 52), 2 => (r.next() >> r.below(52)) as f64 as f64 as f64 as u64 ^ 0, _ => (r.next() >> (r.below(64))) as f64 as u64 }; let b = if b == 0 && r.chance(10) { r.next() } else { b }; let b = if r.below(4) >= 2 { ((r.next() >> r.below(64)) as f64).to_bits() } else { b }; out.extend_from_slice(&b.to_le_bytes()); } }
        "f64" => { std::io::stdin().read_to_end(&mut inp).unwrap(); for c in inp.chunks(8) { f64_case(u64::from_le_bytes(c.try_into().unwrap()), &mut out); } }
        "gen-uni" => { // records: (haystack, needle) pairs
            let n: u64 = args[2].parse().unwrap(); let mut r = Rng(args[3].parse().unwrap());
            let pool: Vec<char> = "aZ \t\n\u{a0}\u{85}\u{3000}\u{2028}\u{3a3}\u{3c3}\u{301}\u{345}'.:\u{130}\u{1E9E}\u{2126}\u{212a}\u{10400}\u{1e921}\u{e0001}\u{ad}\u{0}\u{7f}\"\\\u{200b}\u{feff}\u{1f600}xyzKk\u{3c2}".chars().collect();
            let mut prev = String::from("a");
            for u in 0..=0x10FFFFu32 { if let Some(c) = char::from_u32(u) { put(&mut out, c.to_string().as_bytes()); put(&mut out, c.to_string().as_bytes()); } }
            for _ in 0..n { let mut s = String::new(); let len = r.below(16); for _ in 0..len { if r.chance(700) { s.push(pool[r.below(pool.len() as u64) as usize]); } else { s.push(char::from_u32(r.below(0x110000) as u32).unwrap_or('q')); } }
                let nd: String = if r.chance(500) { let cs: Vec<char> = s.chars().collect(); if cs.is_empty() { String::new() } else { let a = r.below(cs.len() as u64) as usize; let b = a + r.below((cs.len() - a) as u64 + 1) as usize; cs[a..b].iter().collect::<String>().to_uppercase() } } else { prev.chars().take(r.below(3) as usize).collect() };
                put(&mut out, s.as_bytes()); put(&mut out, nd.as_bytes()); prev = s; } }
        "uni" => { std::io::stdin().read_to_end(&mut inp).unwrap(); let recs = records(&inp);
            for pr in recs.chunks(2) { let s = std::str::from_utf8(pr[0]).unwrap(); let nd = std::str::from_utf8(pr[1]).unwrap();
                let mut rec = Vec::new(); put(&mut rec, s.to_lowercase().as_bytes());
                let t = s.trim(); let st = t.as_ptr() as usize - s.as_ptr() as usize; put(&mut rec, format!("{} {}", st, t.len()).as_bytes());
                put(&mut rec, format!("{:?}", s).as_bytes());
                put(&mut rec, if s.to_lowercase().contains(&nd.to_lowercase()) { b"1" } else { b"0" });
                put(&mut out, &rec); } }
        "time" => { // input: i64 ns values then 16-byte uuid inputs; output: rfc3339 / uuid text records
            std::io::stdin().read_to_end(&mut inp).unwrap(); let n = u32::from_le_bytes(inp[0..4].try_into().unwrap()) as usize;
            for k in 0..n { let ns = i64::from_le_bytes(inp[4 + 8 * k..12 + 8 * k].try_into().unwrap()); put(&mut out, chrono::DateTime::<chrono::Utc>::from_timestamp_nanos(ns).to_rfc3339().as_bytes()); }
            for c in inp[4 + 8 * n..].chunks(16) { put(&mut out, uuid::Builder::from_random_bytes(c.try_into().unwrap()).into_uuid().to_string().as_bytes()); } }
        "gen-time" => { let n: u64 = args[2].parse().unwrap(); let mut r = Rng(args[3].parse().unwrap()); out.extend_from_slice(&(n as u32).to_le_bytes());
            for i in 0..n { let base = (r.next() % 9_000_000_000_000_000_000) as i64; let ns = match i % 5 { 0 => base, 1 => base / 1_000_000_000 * 1_000_000_000, 2 => base / 1_000_000 * 1_000_000, 3 => base / 1000 * 1000, _ => [0i64, 951782400000000000, 4107542399999999999, 1_000_000_000, 1][(i / 5 % 5) as usize] }; out.extend_from_slice(&ns.to_le_bytes()); }
            for _ in 0..n { out.extend_from_slice(&r.next().to_le_bytes()); out.extend_from_slice(&r.next().to_le_bytes()); } }
        "gen-api" => { let n: u64 = args[2].parse().unwrap(); let mut r = Rng(args[3].parse().unwrap()); for _ in 0..n { put(&mut out, &api_doc(&mut r)); } }
        "api" => { std::io::stdin().read_to_end(&mut inp).unwrap(); for d in records(&inp) {
            let m = match serde_json::from_slice::<Q>(d) { Ok(_) => "OK".to_string(), Err(e) => { let t = e.to_string(); let k = if t.starts_with("invalid type") { "type" } else if t.starts_with("missing field") { "missing" } else if t.starts_with("duplicate field") { "duplicate" } else { "other" }; format!("{} {} {}", k, e.line(), e.column()) } };
            put(&mut out, m.as_bytes()); } }
        _ => panic!("mode"),
    }
    std::io::stdout().write_all(&out).unwrap();
}
