// Black-box Unicode table generator: queries rustc's std (str::to_lowercase, char::is_whitespace).
// Output lines: L <cp> <cp1> [<cp2> ...]   (lower(c) != c, single-char context)
//               K <cp> <class>              class C (cased, not case-ignorable) / I (case-ignorable)
//               W <cp>                      char::is_whitespace
//               D <cp>                      <str as Debug> writes \u{hex} for this char
fn lw(s: &str) -> String { s.to_lowercase() }
fn main() {
    let sig = 'Σ';
    for u in 0u32..=0x10FFFF {
        let c = match char::from_u32(u) { Some(c) => c, None => continue };
        let mut one = String::new(); one.push(c);
        let lo = lw(&one);
        if lo != one {
            let mut line = format!("L {}", u);
            for d in lo.chars() { line.push_str(&format!(" {}", d as u32)); }
            println!("{}", line);
        }
        if c.is_whitespace() { println!("W {}", u); }
        let dbg = format!("{:?}", one);
        let plain = format!("\"{}\"", c);
        if !matches!(c, '\0' | '\t' | '\r' | '\n' | '\\' | '"') && dbg != plain {
            assert_eq!(dbg, format!("\"\\u{{{:x}}}\"", u), "cp {}", u);
            println!("D {}", u);
        }
        if c == sig { println!("K {} C", u); continue; }
        let x1 = lw(&format!("{}{}", c, sig)).ends_with('ς');
        let x2 = lw(&format!("A{}{}", c, sig)).ends_with('ς');
        let y = lw(&format!("A{}{}", sig, c)).starts_with("aς");
        assert_eq!(y, !x1, "cp {}", u);
        if x1 { println!("K {} C", u); } else if x2 { println!("K {} I", u); }
    }
}
