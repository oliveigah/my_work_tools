//! Just enough JSON for an ACP proxy: read a message to look at a few of its
//! fields, and write the few messages of its own. Lines are forwarded as
//! they came, never re-serialized, so nothing here needs to round-trip.
//!
//! Numbers stay as their text: an id is compared by how it was written.
//! `parse_lenient` also takes comments and trailing commas, as in Zed's
//! settings files.

use std::fmt::Write as _;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(String),
    String(String),
    Array(Vec<Value>),
    Object(Vec<(String, Value)>),
}

impl Value {
    /// The value of `key` in an object (the last one when it repeats).
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(members) => members.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// The value at a path of object keys.
    pub fn at(&self, path: &[&str]) -> Option<&Value> {
        path.iter().try_fold(self, |value, key| value.get(key))
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    /// Sets `key` in an object: in the place of its first value (dropping
    /// any repeats), or at the end.
    pub fn set(&mut self, key: &str, value: Value) {
        if let Value::Object(members) = self {
            match members.iter().position(|(k, _)| k == key) {
                Some(first) => {
                    members[first].1 = value;
                    let mut index = 0;
                    members.retain(|(k, _)| {
                        index += 1;
                        index - 1 == first || k != key
                    });
                }
                None => members.push((key.to_string(), value)),
            }
        }
    }

    /// Drops `key`, every value of it, from an object.
    pub fn remove(&mut self, key: &str) {
        if let Value::Object(members) = self {
            members.retain(|(k, _)| k != key);
        }
    }

    /// The value as one line of JSON.
    pub fn to_json(&self) -> String {
        let mut out = String::new();
        write_value(self, &mut out, None, 0);
        out
    }

    /// The value as JSON indented by two spaces, for files people read.
    pub fn to_pretty(&self) -> String {
        let mut out = String::new();
        write_value(self, &mut out, Some(2), 0);
        out.push('\n');
        out
    }
}

/// Shorthand for building an object.
pub fn object(members: Vec<(&str, Value)>) -> Value {
    Value::Object(
        members
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect(),
    )
}

pub fn string(s: &str) -> Value {
    Value::String(s.to_string())
}

/// Parses exactly one JSON value, with only whitespace around it.
pub fn parse(text: &str) -> Result<Value, String> {
    Parser::new(text, false).document()
}

/// As `parse`, also taking `//` and `/* */` comments and trailing commas.
pub fn parse_lenient(text: &str) -> Result<Value, String> {
    Parser::new(text, true).document()
}

/// A JSON string literal, quotes included.
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    write_string(s, &mut out);
    out
}

// Deeper than any message ACP sends; it keeps a hostile line from
// exhausting the stack.
const MAX_DEPTH: usize = 256;

struct Parser<'a> {
    bytes: &'a [u8],
    text: &'a str,
    pos: usize,
    lenient: bool,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str, lenient: bool) -> Self {
        Parser {
            bytes: text.as_bytes(),
            text,
            pos: 0,
            lenient,
        }
    }

    fn document(mut self) -> Result<Value, String> {
        self.space()?;
        let value = self.value(0)?;
        self.space()?;
        if self.pos != self.bytes.len() {
            return Err(self.error("text after the value"));
        }
        Ok(value)
    }

    fn error(&self, what: &str) -> String {
        format!("{what} at byte {}", self.pos)
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn space(&mut self) -> Result<(), String> {
        loop {
            match self.peek() {
                Some(b' ' | b'\t' | b'\n' | b'\r') => self.pos += 1,
                Some(b'/') if self.lenient => self.comment()?,
                _ => return Ok(()),
            }
        }
    }

    fn comment(&mut self) -> Result<(), String> {
        match self.bytes.get(self.pos + 1) {
            Some(b'/') => {
                while let Some(b) = self.peek() {
                    self.pos += 1;
                    if b == b'\n' {
                        break;
                    }
                }
                Ok(())
            }
            Some(b'*') => {
                self.pos += 2;
                loop {
                    match self.peek() {
                        None => return Err(self.error("unclosed comment")),
                        Some(b'*') if self.bytes.get(self.pos + 1) == Some(&b'/') => {
                            self.pos += 2;
                            return Ok(());
                        }
                        Some(_) => self.pos += 1,
                    }
                }
            }
            _ => Err(self.error("unexpected '/'")),
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value, String> {
        if depth > MAX_DEPTH {
            return Err(self.error("nested too deep"));
        }
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b't') => self.word("true", Value::Bool(true)),
            Some(b'f') => self.word("false", Value::Bool(false)),
            Some(b'n') => self.word("null", Value::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.error("unexpected character")),
            None => Err(self.error("unexpected end")),
        }
    }

    fn word(&mut self, word: &str, value: Value) -> Result<Value, String> {
        if self.text[self.pos..].starts_with(word) {
            self.pos += word.len();
            Ok(value)
        } else {
            Err(self.error("unexpected word"))
        }
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => self.digits(),
            _ => return Err(self.error("bad number")),
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.error("bad number"));
            }
            self.digits();
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.error("bad number"));
            }
            self.digits();
        }
        Ok(Value::Number(self.text[start..self.pos].to_string()))
    }

    fn digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.pos += 1; // the opening quote
        let mut out = String::new();
        loop {
            // Copy the plain run in one go: most strings have no escapes.
            let run = self.pos;
            while let Some(b) = self.peek() {
                if b == b'"' || b == b'\\' || b < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            out.push_str(&self.text[run..self.pos]);
            match self.peek() {
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    self.escape(&mut out)?;
                }
                Some(_) => return Err(self.error("control character in string")),
                None => return Err(self.error("unclosed string")),
            }
        }
    }

    fn escape(&mut self, out: &mut String) -> Result<(), String> {
        let b = self.peek().ok_or_else(|| self.error("unclosed string"))?;
        self.pos += 1;
        match b {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{8}'),
            b'f' => out.push('\u{c}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => {
                let first = self.hex4()?;
                let code = if (0xD800..0xDC00).contains(&first) {
                    if self.bytes.get(self.pos) != Some(&b'\\')
                        || self.bytes.get(self.pos + 1) != Some(&b'u')
                    {
                        return Err(self.error("lone surrogate"));
                    }
                    self.pos += 2;
                    let second = self.hex4()?;
                    if !(0xDC00..0xE000).contains(&second) {
                        return Err(self.error("lone surrogate"));
                    }
                    0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                } else if (0xDC00..0xE000).contains(&first) {
                    return Err(self.error("lone surrogate"));
                } else {
                    first
                };
                out.push(char::from_u32(code).ok_or_else(|| self.error("bad escape"))?);
            }
            _ => return Err(self.error("bad escape")),
        }
        Ok(())
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let digits = self
            .text
            .get(self.pos..self.pos + 4)
            .ok_or_else(|| self.error("bad escape"))?;
        let code = u32::from_str_radix(digits, 16).map_err(|_| self.error("bad escape"))?;
        self.pos += 4;
        Ok(code)
    }

    fn array(&mut self, depth: usize) -> Result<Value, String> {
        self.pos += 1;
        let mut items = Vec::new();
        loop {
            self.space()?;
            if self.peek() == Some(b']') && (items.is_empty() || self.lenient) {
                self.pos += 1;
                return Ok(Value::Array(items));
            }
            items.push(self.value(depth + 1)?);
            self.space()?;
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Array(items));
                }
                _ => return Err(self.error("expected ',' or ']'")),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value, String> {
        self.pos += 1;
        let mut members = Vec::new();
        loop {
            self.space()?;
            if self.peek() == Some(b'}') && (members.is_empty() || self.lenient) {
                self.pos += 1;
                return Ok(Value::Object(members));
            }
            if self.peek() != Some(b'"') {
                return Err(self.error("expected a key"));
            }
            let key = self.string()?;
            self.space()?;
            if self.peek() != Some(b':') {
                return Err(self.error("expected ':'"));
            }
            self.pos += 1;
            self.space()?;
            let value = self.value(depth + 1)?;
            members.push((key, value));
            self.space()?;
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Object(members));
                }
                _ => return Err(self.error("expected ',' or '}'")),
            }
        }
    }
}

fn write_value(value: &Value, out: &mut String, indent: Option<usize>, level: usize) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(n),
        Value::String(s) => write_string(s, out),
        Value::Array(items) if items.is_empty() => out.push_str("[]"),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                newline(out, indent, level + 1);
                write_value(item, out, indent, level + 1);
            }
            newline(out, indent, level);
            out.push(']');
        }
        Value::Object(members) if members.is_empty() => out.push_str("{}"),
        Value::Object(members) => {
            out.push('{');
            for (i, (key, item)) in members.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                newline(out, indent, level + 1);
                write_string(key, out);
                out.push(':');
                if indent.is_some() {
                    out.push(' ');
                }
                write_value(item, out, indent, level + 1);
            }
            newline(out, indent, level);
            out.push('}');
        }
    }
}

fn newline(out: &mut String, indent: Option<usize>, level: usize) {
    if let Some(width) = indent {
        out.push('\n');
        out.extend(std::iter::repeat(' ').take(width * level));
    }
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_fields_of_a_message() {
        let v = parse(r#"{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/work/a b","mcpServers":[]}}"#).unwrap();
        assert_eq!(v.get("method").and_then(Value::as_str), Some("session/new"));
        assert_eq!(v.get("id"), Some(&Value::Number("7".into())));
        assert_eq!(
            v.at(&["params", "cwd"]).and_then(Value::as_str),
            Some("/work/a b")
        );
        assert_eq!(
            v.at(&["params", "mcpServers"])
                .and_then(Value::as_array)
                .map(|a| a.len()),
            Some(0)
        );
        assert_eq!(v.at(&["params", "missing"]), None);
    }

    #[test]
    fn keeps_numbers_as_written() {
        let v = parse(r#"[0, -1.5e3, 12345678901234567890]"#).unwrap();
        assert_eq!(v.to_json(), "[0,-1.5e3,12345678901234567890]");
    }

    #[test]
    fn unescapes_strings() {
        let v = parse(r#""a\"b\\c\/d\n\t\u00e9\ud83d\ude00""#).unwrap();
        assert_eq!(v, Value::String("a\"b\\c/d\n\té😀".into()));
    }

    #[test]
    fn writes_strings_that_read_back() {
        let s = "line\nnext \"quoted\" \\ tab\t bell\u{7} é 😀";
        assert_eq!(parse(&quote(s)).unwrap(), Value::String(s.into()));
    }

    #[test]
    fn refuses_what_is_not_json() {
        for bad in [
            "",
            "{",
            "{\"a\":}",
            "[1,]",
            "{\"a\":1,}",
            "tru",
            "01",
            "1.",
            "\"\\x\"",
            "\"\\ud800\"",
            "\"a\nb\"",
            "{} {}",
            "{a:1}",
            "// c\n1",
        ] {
            assert!(parse(bad).is_err(), "{bad:?} should not parse");
        }
    }

    #[test]
    fn refuses_deep_nesting() {
        let deep = "[".repeat(MAX_DEPTH + 2) + &"]".repeat(MAX_DEPTH + 2);
        assert!(parse(&deep).is_err());
    }

    #[test]
    fn lenient_takes_comments_and_trailing_commas() {
        let text = "// Zed settings\n{\n  /* agents */ \"agent_servers\": {\"a\": [1, 2,],},\n}\n";
        let v = parse_lenient(text).unwrap();
        assert_eq!(
            v.at(&["agent_servers", "a"])
                .and_then(Value::as_array)
                .map(|a| a.len()),
            Some(2)
        );
        assert!(parse(text).is_err());
    }

    #[test]
    fn set_replaces_or_appends() {
        let mut v = parse(r#"{"a":1,"b":2,"a":3}"#).unwrap();
        v.set("a", Value::Bool(true));
        v.set("c", Value::Null);
        assert_eq!(v.to_json(), r#"{"a":true,"b":2,"c":null}"#);
    }

    #[test]
    fn pretty_prints() {
        let v = parse(r#"{"a":{"b":[1,"x"]},"c":{}}"#).unwrap();
        assert_eq!(
            v.to_pretty(),
            "{\n  \"a\": {\n    \"b\": [\n      1,\n      \"x\"\n    ]\n  },\n  \"c\": {}\n}\n"
        );
    }
}
