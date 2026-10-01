// Python `datetime.date` / `datetime.datetime` and `dateutil.relativedelta` semantics
// used by the simplifier.

///|
/// A Python `date` (when `is_datetime` is false) or `datetime`.
priv struct PyDT {
  y : Int
  m : Int
  d : Int
  is_datetime : Bool
  h : Int
  mi : Int
  s : Int
  us : Int
  /// UTC offset in seconds for aware datetimes
  tz : Int?
}

///|
fn make_date(y : Int, m : Int, d : Int) -> PyDT {
  { y, m, d, is_datetime: false, h: 0, mi: 0, s: 0, us: 0, tz: None }
}

///|
/// Days since 0001-01-01 (Python `toordinal()`).
fn days_from_civil(y : Int, m : Int, d : Int) -> Int {
  let y2 = if m <= 2 { y - 1 } else { y }
  let era = (if y2 >= 0 { y2 } else { y2 - 399 }) / 400
  let yoe = y2 - era * 400
  let mp = (m + 9) % 12
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  // 719163 = days from 0001-01-01 to 1970-01-01 plus one
  era * 146097 + doe - 719468 + 719163
}

///|
fn civil_from_days(n : Int) -> (Int, Int, Int) {
  let z = n - 719163 + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  (if m <= 2 { y + 1 } else { y }, m, d)
}

///|
fn PyDT::ordinal(self : PyDT) -> Int {
  days_from_civil(self.y, self.m, self.d)
}

///|
/// Monday is 0.
fn PyDT::weekday(self : PyDT) -> Int {
  (self.ordinal() + 6) % 7
}

///|
fn check_year(y : Int) -> Unit raise @core.SqlglotError {
  if y < 1 || y > 9999 {
    raise @core.ValueError("year \{y} is out of range")
  }
}

///|
/// Adds days/seconds/microseconds (Python `+ timedelta(...)`).
fn PyDT::add_timedelta(
  self : PyDT,
  days : Int,
  seconds : Int64,
  microseconds : Int64,
) -> PyDT raise @core.SqlglotError {
  self.add_timedelta_big(
    big(days),
    @bigint.BigInt::from_int64(seconds),
    @bigint.BigInt::from_int64(microseconds),
  )
}

///|
/// `OverflowError` (reported as a `ValueError` whose message names the Python type).
fn overflow_error(msg : String) -> @core.SqlglotError {
  @core.ValueError("OverflowError: \{msg}")
}

///|
/// Python's `_PyLong_AsInt`: the value as a C int, or `OverflowError`.
fn c_int(v : @bigint.BigInt) -> Int raise @core.SqlglotError {
  if v < big(-2147483647 - 1) || v > big(2147483647) {
    raise overflow_error("Python int too large to convert to C int")
  }
  v.to_int()
}

///|
/// Python floor division and modulo of big integers by a positive `base`.
fn big_floor_divmod(
  v : @bigint.BigInt,
  base : @bigint.BigInt,
) -> (@bigint.BigInt, @bigint.BigInt) {
  let q = v / base
  let r = v - q * base
  if r < big(0) {
    (q - big(1), r + base)
  } else {
    (q, r)
  }
}

///|
/// `self + timedelta(days=days, seconds=seconds, microseconds=microseconds)` with
/// Python's range checks: the normalized day count must fit a C int and have magnitude
/// <= 999999999, and the result must lie in years 1..9999 (`OverflowError` otherwise).
fn PyDT::add_timedelta_big(
  self : PyDT,
  days : @bigint.BigInt,
  seconds : @bigint.BigInt,
  microseconds : @bigint.BigInt,
) -> PyDT raise @core.SqlglotError {
  // timedelta(...) normalization
  let us_per_day = @bigint.BigInt::from_int64(86400000000L)
  let delta_us = (days * big(86400) + seconds) * big(1000000) + microseconds
  let (delta_days_big, delta_rem) = big_floor_divmod(delta_us, us_per_day)
  let delta_days = c_int(delta_days_big)
  if delta_days < -999999999 || delta_days > 999999999 {
    raise overflow_error("days=\{delta_days}; must have magnitude <= 999999999")
  }
  let total_us = (
      self.h.to_int64() * 3600L + self.mi.to_int64() * 60L + self.s.to_int64()
    ) *
    1000000L +
    self.us.to_int64() +
    delta_rem.to_int64()
  let day_us = 86400000000L
  let mut extra_days = total_us / day_us
  let mut rem = total_us % day_us
  if rem < 0L {
    rem = rem + day_us
    extra_days = extra_days - 1L
  }
  // date.max.toordinal() == 3652059
  let ord = self.ordinal().to_int64() + delta_days.to_int64() + extra_days
  if ord < 1L || ord > 3652059L {
    raise overflow_error("date value out of range")
  }
  let (y, m, d) = civil_from_days(ord.to_int())
  let secs = (rem / 1000000L).to_int()
  {
    ..self,
    y,
    m,
    d,
    h: secs / 3600,
    mi: secs % 3600 / 60,
    s: secs % 60,
    us: (rem % 1000000L).to_int(),
  }
}

///|
fn PyDT::to_datetime(self : PyDT) -> PyDT {
  if self.is_datetime {
    self
  } else {
    { ..self, is_datetime: true }
  }
}

///|
fn PyDT::to_date(self : PyDT) -> PyDT {
  make_date(self.y, self.m, self.d)
}

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    n.to_string()
  }
}

///|
fn pad_n(n : Int, width : Int) -> String {
  let s = n.to_string()
  if s.length() >= width {
    s
  } else {
    "0".repeat(width - s.length()) + s
  }
}

///|
/// Python `str(date)` / `str(datetime)`.
fn PyDT::to_py_string(self : PyDT) -> String {
  let date = "\{pad_n(self.y, 4)}-\{pad2(self.m)}-\{pad2(self.d)}"
  if !self.is_datetime {
    return date
  }
  let mut out = date + " \{pad2(self.h)}:\{pad2(self.mi)}:\{pad2(self.s)}"
  if self.us != 0 {
    out += "." + pad_n(self.us, 6)
  }
  match self.tz {
    Some(off) => {
      let sign = if off < 0 { "-" } else { "+" }
      let a = if off < 0 { -off } else { off }
      out += "\{sign}\{pad2(a / 3600)}:\{pad2(a % 3600 / 60)}"
      if a % 60 != 0 {
        out += ":\{pad2(a % 60)}"
      }
    }
    None => ()
  }
  out
}

///|
/// Microseconds since epoch-ish (for ordering), adjusted by the UTC offset.
fn PyDT::instant(self : PyDT) -> Int64 {
  let secs = self.ordinal().to_int64() * 86400L +
    self.h.to_int64() * 3600L +
    self.mi.to_int64() * 60L +
    self.s.to_int64() -
    self.tz.unwrap_or(0).to_int64()
  secs * 1000000L + self.us.to_int64()
}

///|
/// Python `a == b` for dates/datetimes.
fn pydt_eq(a : PyDT, b : PyDT) -> Bool {
  if a.is_datetime != b.is_datetime {
    return false
  }
  if a.tz is Some(_) != (b.tz is Some(_)) {
    return false
  }
  a.instant() == b.instant()
}

///|
/// Python ordering comparison; raises like Python's TypeError on mixed kinds.
fn pydt_cmp(a : PyDT, b : PyDT) -> Int raise @core.SqlglotError {
  if a.is_datetime != b.is_datetime {
    raise @core.ValueError("TypeError: can't compare datetime.datetime to datetime.date")
  }
  if a.tz is Some(_) != (b.tz is Some(_)) {
    raise @core.ValueError(
      "TypeError: can't compare offset-naive and offset-aware datetimes",
    )
  }
  a.instant().compare(b.instant())
}

///|
/// Python `datetime.fromisoformat(text)` (or `None` on ValueError).
fn parse_py_datetime(text : String) -> PyDT? {
  let chars = text.to_array()
  let (y, m, d, n) = match parse_iso_date_parts(chars) {
    Some(x) => x
    None => return None
  }
  let base = { ..make_date(y, m, d), is_datetime: true }
  if n == chars.length() {
    return Some(base)
  }
  if n + 1 >= chars.length() {
    return None
  }
  parse_iso_time_parts(chars[n + 1:].to_array()).map(t => {
    ..base,
    h: t.0,
    mi: t.1,
    s: t.2,
    us: t.3,
    tz: t.4,
  })
}

///|
/// Python 3.11+ ISO date forms; returns (year, month, day, consumed).
fn parse_iso_date_parts(chars : Array[Char]) -> (Int, Int, Int, Int)? {
  let n = match parse_iso_date_prefix(chars) {
    Some(n) => n
    None => return None
  }
  let year = digits_at(chars, 0, 4).unwrap()
  // week dates
  let (w, wd) = if chars[4] == 'W' {
    (digits_at(chars, 5, 2), if n == 8 { digits_at(chars, 7, 1) } else { Some(1) })
  } else if chars[4] == '-' && chars[5] == 'W' {
    (digits_at(chars, 6, 2), if n == 10 { digits_at(chars, 9, 1) } else { Some(1) })
  } else {
    (None, None)
  }
  match (w, wd) {
    (Some(week), Some(day)) => {
      // ISO week 1 contains Jan 4th
      let jan4 = make_date(year, 1, 4)
      let week1_monday = jan4.ordinal() - jan4.weekday()
      let (yy, mm, dd) = civil_from_days(week1_monday + (week - 1) * 7 + day - 1)
      Some((yy, mm, dd, n))
    }
    _ =>
      if chars[4] == '-' {
        Some((year, digits_at(chars, 5, 2).unwrap(), digits_at(chars, 8, 2).unwrap(), n))
      } else {
        Some((year, digits_at(chars, 4, 2).unwrap(), digits_at(chars, 6, 2).unwrap(), n))
      }
  }
}

///|
/// Parses HH[:MM[:SS[.f+]]] (or basic form) plus an optional UTC offset.
fn parse_iso_time_parts(arr : Array[Char]) -> (Int, Int, Int, Int, Int?)? {
  if !is_iso_time(arr[:]) {
    return None
  }
  let n = arr.length()
  let h = digits_at(arr, 0, 2).unwrap()
  let mut i = 2
  let extended = i < n && arr[i] == ':'
  let mut mi = 0
  let mut s = 0
  let mut us = 0
  let is_tz_start = fn(c : Char) { c == '+' || c == '-' || c == 'Z' }
  if i < n && !is_tz_start(arr[i]) {
    if extended {
      i += 1
    }
    mi = digits_at(arr, i, 2).unwrap()
    i += 2
    if i < n && !is_tz_start(arr[i]) {
      if extended {
        i += 1
      }
      s = digits_at(arr, i, 2).unwrap()
      i += 2
      if i < n && (arr[i] == '.' || arr[i] == ',') {
        i += 1
        let mut digits = 0
        let mut v = 0
        while i < n && arr[i] >= '0' && arr[i] <= '9' {
          if digits < 6 {
            v = v * 10 + (arr[i].to_int() - '0'.to_int())
            digits += 1
          }
          i += 1
        }
        while digits < 6 {
          v = v * 10
          digits += 1
        }
        us = v
      }
    }
  }
  let tz = if i >= n {
    None
  } else if arr[i] == 'Z' {
    Some(0)
  } else {
    let sign = if arr[i] == '-' { -1 } else { 1 }
    i += 1
    let th = digits_at(arr, i, 2).unwrap()
    i += 2
    let mut tm = 0
    let mut ts = 0
    if i < n {
      if arr[i] == ':' {
        i += 1
      }
      tm = digits_at(arr, i, 2).unwrap_or(0)
      i += 2
      if i < n {
        if arr[i] == ':' {
          i += 1
        }
        ts = digits_at(arr, i, 2).unwrap_or(0)
      }
    }
    Some(sign * (th * 3600 + tm * 60 + ts))
  }
  Some((h, mi, s, us, tz))
}

///|
/// A `dateutil.relativedelta` (normalized as by its `_fix`). Python ints are unbounded,
/// so the components are big integers.
priv struct RelDelta {
  years : @bigint.BigInt
  months : @bigint.BigInt
  days : @bigint.BigInt
  hours : @bigint.BigInt
  minutes : @bigint.BigInt
  seconds : @bigint.BigInt
  microseconds : @bigint.BigInt
}

///|
fn sign_divmod(
  v : @bigint.BigInt,
  base : Int,
) -> (@bigint.BigInt, @bigint.BigInt) {
  // Python: s = sign(v); div, mod = divmod(v * s, base); return (div * s, mod * s)
  let s = if v < big(0) { big(-1) } else { big(1) }
  let a = v * s
  let b = big(base)
  (a / b * s, a % b * s)
}

///|
fn RelDelta::fix(self : RelDelta) -> RelDelta {
  let mut r = self
  let out_of = (v : @bigint.BigInt, limit : Int) => {
    v > big(limit) || v < big(-limit)
  }
  if out_of(r.microseconds, 999999) {
    let (div, md) = sign_divmod(r.microseconds, 1000000)
    r = { ..r, microseconds: md, seconds: r.seconds + div }
  }
  if out_of(r.seconds, 59) {
    let (div, md) = sign_divmod(r.seconds, 60)
    r = { ..r, seconds: md, minutes: r.minutes + div }
  }
  if out_of(r.minutes, 59) {
    let (div, md) = sign_divmod(r.minutes, 60)
    r = { ..r, minutes: md, hours: r.hours + div }
  }
  if out_of(r.hours, 23) {
    let (div, md) = sign_divmod(r.hours, 24)
    r = { ..r, hours: md, days: r.days + div }
  }
  if out_of(r.months, 11) {
    let (div, md) = sign_divmod(r.months, 12)
    r = { ..r, months: md, years: r.years + div }
  }
  r
}

///|
fn RelDelta::zero() -> RelDelta {
  {
    years: big(0),
    months: big(0),
    days: big(0),
    hours: big(0),
    minutes: big(0),
    seconds: big(0),
    microseconds: big(0),
  }
}

///|
fn RelDelta::neg(self : RelDelta) -> RelDelta {
  {
    years: -self.years,
    months: -self.months,
    days: -self.days,
    hours: -self.hours,
    minutes: -self.minutes,
    seconds: -self.seconds,
    microseconds: -self.microseconds,
  }.fix()
}

///|
fn RelDelta::has_time(self : RelDelta) -> Bool {
  !self.hours.is_zero() ||
  !self.minutes.is_zero() ||
  !self.seconds.is_zero() ||
  !self.microseconds.is_zero()
}

///|
fn RelDelta::moves_months(self : RelDelta) -> Bool {
  !self.months.is_zero() || !self.years.is_zero()
}

///|
/// `calendar.monthrange(year, month)[1]` for any year (the leap pattern repeats every
/// 400 years).
fn days_in_month_big(year : @bigint.BigInt, month : Int) -> Int {
  let (_, y400) = big_floor_divmod(year, big(400))
  // 2000 + y400 has the same leap status as `year`
  days_in_month(2000 + y400.to_int(), month)
}

///|
/// `other + relativedelta`
fn add_reldelta(other : PyDT, rd : RelDelta) -> PyDT raise @core.SqlglotError {
  let other = if rd.has_time() && !other.is_datetime {
    other.to_datetime()
  } else {
    other
  }
  let mut year = big(other.y) + rd.years
  let mut month = other.m
  if !rd.months.is_zero() {
    // |months| <= 11 after `fix`
    month += rd.months.to_int()
    if month > 12 {
      year = year + big(1)
      month -= 12
    } else if month < 1 {
      year = year - big(1)
      month += 12
    }
  }
  let day = @core.min_int(days_in_month_big(year, month), other.d)
  // other.replace(year=year, ...)
  let year = c_int(year)
  check_year(year)
  let replaced = { ..other, y: year, m: month, d: day }
  replaced.add_timedelta_big(
    rd.days,
    rd.hours * big(3600) + rd.minutes * big(60) + rd.seconds,
    rd.microseconds,
  )
}

///|
/// Python `interval(unit, n)`; `None` for unsupported units.
fn interval_delta(unit : String, n? : @bigint.BigInt = big(1)) -> RelDelta? {
  let z = RelDelta::zero()
  let r = match unit {
    "year" => { ..z, years: n }
    "quarter" => { ..z, months: big(3) * n }
    "month" => { ..z, months: n }
    "week" => { ..z, days: big(7) * n }
    "day" => { ..z, days: n }
    "hour" => { ..z, hours: n }
    "minute" => { ..z, minutes: n }
    "second" => { ..z, seconds: n }
    "millisecond" => { ..z, microseconds: big(1000) * n }
    "microsecond" => { ..z, microseconds: n }
    _ => return None
  }
  Some(r.fix())
}

///|
/// Python `datetime_floor`; `None` for unsupported units.
fn datetime_floor(d : PyDT, unit : String, week_offset : Int) -> PyDT? {
  if d.is_datetime {
    match unit {
      "hour" => return Some({ ..d, mi: 0, s: 0, us: 0 })
      "minute" => return Some({ ..d, s: 0, us: 0 })
      "second" => return Some({ ..d, us: 0 })
      "millisecond" => return Some({ ..d, us: d.us / 1000 * 1000 })
      "microsecond" => return Some(d)
      _ => ()
    }
  }
  let result = match unit {
    "year" => { ..d, m: 1, d: 1 }
    "quarter" => {
      let m = if d.m <= 3 {
        1
      } else if d.m <= 6 {
        4
      } else if d.m <= 9 {
        7
      } else {
        10
      }
      { ..d, m, d: 1 }
    }
    "month" => { ..d, d: 1 }
    "week" => {
      let back = ((d.weekday() - week_offset) % 7 + 7) % 7
      let (y, m, dd) = civil_from_days(d.ordinal() - back)
      { ..d, y, m, d: dd }
    }
    "day" => d
    _ => return None
  }
  if result.is_datetime {
    Some({ ..result, h: 0, mi: 0, s: 0, us: 0 })
  } else {
    Some(result)
  }
}
