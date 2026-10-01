// Python `helper.is_iso_date` / `is_iso_datetime` / `is_date_unit`.

///|
let date_units : Array[String] = [
  "day", "week", "month", "quarter", "year", "year_month",
]

///|
fn is_date_unit(expression : @core.Expr?) -> Bool {
  match expression {
    Some(e) => date_units.contains(@core.py_lower(e.name()))
    None => false
  }
}

///|
fn digits_at(chars : Array[Char], start : Int, n : Int) -> Int? {
  if start + n > chars.length() {
    return None
  }
  let mut v = 0
  for i in start..<(start + n) {
    let c = chars[i]
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  Some(v)
}

///|
fn days_in_month(year : Int, month : Int) -> Int {
  match month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    2 =>
      if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
        29
      } else {
        28
      }
    _ => 0
  }
}

///|
/// Parses an ISO date prefix, returning the number of chars consumed (Python 3.11+
/// `date.fromisoformat` formats: YYYY-MM-DD, YYYYMMDD, YYYY-Www[-D], YYYYWww[D]).
fn parse_iso_date_prefix(chars : Array[Char]) -> Int? {
  let year = match digits_at(chars, 0, 4) {
    Some(y) if y >= 1 => y
    _ => return None
  }
  let n = chars.length()
  if n >= 5 && chars[4] == '-' {
    if n >= 6 && chars[5] == 'W' {
      match digits_at(chars, 6, 2) {
        Some(w) if w >= 1 && w <= 53 =>
          if n >= 10 && chars[8] == '-' {
            match digits_at(chars, 9, 1) {
              Some(d) if d >= 1 && d <= 7 => Some(10)
              _ => None
            }
          } else {
            Some(8)
          }
        _ => None
      }
    } else {
      match (digits_at(chars, 5, 2), n >= 8 && chars[7] == '-', digits_at(chars, 8, 2)) {
        (Some(m), true, Some(d)) if m >= 1 &&
          m <= 12 &&
          d >= 1 &&
          d <= days_in_month(year, m) => Some(10)
        _ => None
      }
    }
  } else if n >= 5 && chars[4] == 'W' {
    match digits_at(chars, 5, 2) {
      Some(w) if w >= 1 && w <= 53 =>
        match digits_at(chars, 7, 1) {
          Some(d) if d >= 1 && d <= 7 => Some(8)
          _ => Some(7)
        }
      _ => None
    }
  } else {
    match (digits_at(chars, 4, 2), digits_at(chars, 6, 2)) {
      (Some(m), Some(d)) if m >= 1 &&
        m <= 12 &&
        d >= 1 &&
        d <= days_in_month(year, m) => Some(8)
      _ => None
    }
  }
}

///|
fn is_iso_date(text : String) -> Bool {
  let chars = text.to_array()
  match parse_iso_date_prefix(chars) {
    Some(n) => n == chars.length()
    None => false
  }
}

///|
/// Parses an ISO time (HH[:MM[:SS[.f+]]] or HH[MM[SS[.f+]]]) followed by an optional
/// UTC offset, returning whether the whole slice was consumed.
fn is_iso_time(chars : ArrayView[Char]) -> Bool {
  let n = chars.length()
  let arr = chars.to_array()
  let hh = match digits_at(arr, 0, 2) {
    Some(h) if h <= 23 => h
    _ => return false
  }
  ignore(hh)
  let mut i = 2
  let extended = i < n && arr[i] == ':'
  // minutes
  if i < n && arr[i] != '+' && arr[i] != '-' && arr[i] != 'Z' {
    if extended {
      i += 1
    }
    match digits_at(arr, i, 2) {
      Some(m) if m <= 59 => i += 2
      _ => return false
    }
    // seconds
    if i < n && arr[i] != '+' && arr[i] != '-' && arr[i] != 'Z' {
      if extended {
        if arr[i] != ':' {
          return false
        }
        i += 1
      }
      match digits_at(arr, i, 2) {
        Some(s) if s <= 59 => i += 2
        _ => return false
      }
      // fraction
      if i < n && (arr[i] == '.' || arr[i] == ',') {
        i += 1
        let start = i
        while i < n && arr[i] >= '0' && arr[i] <= '9' {
          i += 1
        }
        if i == start {
          return false
        }
      }
    }
  }
  if i == n {
    return true
  }
  // UTC offset
  if arr[i] == 'Z' {
    return i + 1 == n
  }
  if arr[i] == '+' || arr[i] == '-' {
    i += 1
    match digits_at(arr, i, 2) {
      Some(h) if h <= 23 => i += 2
      _ => return false
    }
    if i == n {
      return true
    }
    if arr[i] == ':' {
      i += 1
    }
    match digits_at(arr, i, 2) {
      Some(m) if m <= 59 => i += 2
      _ => return false
    }
    if i == n {
      return true
    }
    if arr[i] == ':' {
      i += 1
    }
    match digits_at(arr, i, 2) {
      Some(s) if s <= 59 => i += 2
      _ => return false
    }
    if i < n && arr[i] == '.' {
      i += 1
      while i < n && arr[i] >= '0' && arr[i] <= '9' {
        i += 1
      }
    }
    return i == n
  }
  false
}

///|
fn is_iso_datetime(text : String) -> Bool {
  let chars = text.to_array()
  let n = match parse_iso_date_prefix(chars) {
    Some(n) => n
    None => return false
  }
  if n == chars.length() {
    return true
  }
  // a single separator char followed by a time
  if n + 1 >= chars.length() {
    return false
  }
  is_iso_time(chars[n + 1:])
}
