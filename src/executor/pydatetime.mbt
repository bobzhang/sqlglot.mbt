// A port of the parts of Python's `datetime` module used by the executor.

///|
pub(all) struct PyDate {
  year : Int
  month : Int
  day : Int
} derive(Eq)

///|
pub(all) struct PyTime {
  hour : Int
  minute : Int
  second : Int
  microsecond : Int
} derive(Eq)

///|
/// A `datetime.datetime`; `tz` is the UTC offset in seconds of an aware datetime (only
/// `datetime.timezone.utc`, i.e. 0, is produced by the executor).
pub(all) struct PyDateTime {
  date : PyDate
  time : PyTime
  tz : Int?
}

///|
/// A normalized `datetime.timedelta`.
pub(all) struct PyTimeDelta {
  days : Int64
  seconds : Int
  microseconds : Int
} derive(Eq)

///|
let days_in_month_table : FixedArray[Int] = [
  0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
]

///|
fn is_leap(y : Int) -> Bool {
  y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

///|
fn days_in_month(y : Int, m : Int) -> Int {
  if m == 2 && is_leap(y) {
    29
  } else {
    days_in_month_table[m]
  }
}

///|
/// Python `date.toordinal()`.
fn ordinal(y : Int, m : Int, d : Int) -> Int64 {
  let y1 = (y - 1).to_int64()
  let mut days = y1 * 365L + y1 / 4L - y1 / 100L + y1 / 400L
  for i in 1..<m {
    days += days_in_month(y, i).to_int64()
  }
  days + d.to_int64()
}

///|
/// Python `date.fromordinal(n)`.
fn from_ordinal(n : Int64) -> PyDate raise PyException {
  if n < 1L || n > 3652059L {
    raise PyException("OverflowError", "date value out of range")
  }
  // days since 0001-01-01
  let mut n = n - 1L
  let n400 = n / 146097L
  n = n % 146097L
  let n100 = n / 36524L
  n = n % 36524L
  let n4 = n / 1461L
  n = n % 1461L
  let n1 = n / 365L
  n = n % 365L
  let mut year = (n400 * 400L + n100 * 100L + n4 * 4L + n1 + 1L).to_int()
  if n1 == 4L || n100 == 4L {
    year -= 1
    return { year, month: 12, day: 31, }
  }
  let mut month = 1
  let mut rem = n.to_int()
  while rem >= days_in_month(year, month) {
    rem -= days_in_month(year, month)
    month += 1
  }
  { year, month, day: rem + 1, }
}

///|
fn check_date(y : Int, m : Int, d : Int) -> PyDate raise PyException {
  if y < 1 || y > 9999 {
    raise value_error("year \{y} is out of range")
  }
  if m < 1 || m > 12 {
    raise value_error("month must be in 1..12")
  }
  if d < 1 || d > days_in_month(y, m) {
    raise value_error("day is out of range for month")
  }
  { year: y, month: m, day: d, }
}

///|
fn check_time(h : Int, mi : Int, s : Int, us : Int) -> PyTime raise PyException {
  if h < 0 || h > 23 {
    raise value_error("hour must be in 0..23")
  }
  if mi < 0 || mi > 59 {
    raise value_error("minute must be in 0..59")
  }
  if s < 0 || s > 59 {
    raise value_error("second must be in 0..59")
  }
  if us < 0 || us > 999999 {
    raise value_error("microsecond must be in 0..999999")
  }
  { hour: h, minute: mi, second: s, microsecond: us, }
}

///|
pub fn PyDate::toordinal(self : PyDate) -> Int64 {
  ordinal(self.year, self.month, self.day)
}

///|
/// Python `date.weekday()` (Monday is 0).
pub fn PyDate::weekday(self : PyDate) -> Int {
  ((self.toordinal() + 6L) % 7L).to_int()
}

///|
fn PyDate::compare(self : PyDate, other : PyDate) -> Int {
  self.toordinal().compare(other.toordinal())
}

///|
fn PyTime::compare(self : PyTime, other : PyTime) -> Int {
  self.total_us().compare(other.total_us())
}

///|
fn PyTime::total_us(self : PyTime) -> Int64 {
  ((self.hour * 60 + self.minute) * 60 + self.second).to_int64() * 1000000L +
  self.microsecond.to_int64()
}

///|
/// Microseconds since 0001-01-01 00:00 (naive, local).
fn PyDateTime::total_us(self : PyDateTime) -> Int64 {
  (self.date.toordinal() - 1L) * 86400000000L + self.time.total_us()
}

///|
fn PyDateTime::utc_us(self : PyDateTime) -> Int64 {
  self.total_us() - self.tz.unwrap_or(0).to_int64() * 1000000L
}

///|
fn PyDateTime::eq(self : PyDateTime, other : PyDateTime) -> Bool {
  match (self.tz, other.tz) {
    (None, None) => self.total_us() == other.total_us()
    (Some(_), Some(_)) => self.utc_us() == other.utc_us()
    _ => false
  }
}

///|
fn PyDateTime::compare(
  self : PyDateTime,
  other : PyDateTime,
) -> Int raise PyException {
  match (self.tz, other.tz) {
    (None, None) => self.total_us().compare(other.total_us())
    (Some(_), Some(_)) => self.utc_us().compare(other.utc_us())
    _ =>
      raise type_error("can't compare offset-naive and offset-aware datetimes")
  }
}

///|
fn datetime_from_us(us : Int64, tz : Int?) -> PyDateTime raise PyException {
  let day = floor_div64(us, 86400000000L)
  let rem = us - day * 86400000000L
  let date = from_ordinal(day + 1L)
  let secs = (rem / 1000000L).to_int()
  let micro = (rem % 1000000L).to_int()
  {
    date,
    time: {
      hour: secs / 3600,
      minute: secs / 60 % 60,
      second: secs % 60,
      microsecond: micro,
    },
    tz,
  }
}

///|
fn floor_div64(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  if a % b != 0L && (a < 0L) != (b < 0L) {
    q - 1L
  } else {
    q
  }
}

///|
/// Builds a normalized timedelta from a total number of microseconds.
pub fn PyTimeDelta::from_us(us : Int64) -> PyTimeDelta {
  let days = floor_div64(us, 86400000000L)
  let rem = us - days * 86400000000L
  {
    days,
    seconds: (rem / 1000000L).to_int(),
    microseconds: (rem % 1000000L).to_int(),
  }
}

///|
pub fn PyTimeDelta::total_us(self : PyTimeDelta) -> Int64 {
  self.days * 86400000000L +
  self.seconds.to_int64() * 1000000L +
  self.microseconds.to_int64()
}

///|
fn PyTimeDelta::is_zero(self : PyTimeDelta) -> Bool {
  self.days == 0L && self.seconds == 0 && self.microseconds == 0
}

///|
fn PyTimeDelta::compare(self : PyTimeDelta, other : PyTimeDelta) -> Int {
  self.total_us().compare(other.total_us())
}

///|
fn check_td(td : PyTimeDelta) -> PyTimeDelta raise PyException {
  if td.days < -999999999L || td.days > 999999999L {
    raise PyException(
      "OverflowError",
      "days=\{td.days}; must have magnitude <= 999999999",
    )
  }
  td
}

///|
fn pad(n : Int, width : Int) -> String {
  let s = n.abs().to_string()
  let s = if s.length() < width {
    "0".repeat(width - s.length()) + s
  } else {
    s
  }
  if n < 0 {
    "-" + s
  } else {
    s
  }
}

///|
pub fn PyDate::isoformat(self : PyDate) -> String {
  "\{pad(self.year, 4)}-\{pad(self.month, 2)}-\{pad(self.day, 2)}"
}

///|
pub fn PyTime::isoformat(self : PyTime) -> String {
  let base = "\{pad(self.hour, 2)}:\{pad(self.minute, 2)}:\{pad(self.second, 2)}"
  if self.microsecond != 0 {
    base + "." + pad(self.microsecond, 6)
  } else {
    base
  }
}

///|
fn tz_suffix(tz : Int?) -> String {
  match tz {
    None => ""
    Some(off) => {
      let sign = if off < 0 { "-" } else { "+" }
      let o = off.abs()
      let base = sign + pad(o / 3600, 2) + ":" + pad(o / 60 % 60, 2)
      if o % 60 != 0 {
        base + ":" + pad(o % 60, 2)
      } else {
        base
      }
    }
  }
}

///|
pub fn PyDateTime::isoformat(self : PyDateTime, sep? : String = "T") -> String {
  self.date.isoformat() + sep + self.time.isoformat() + tz_suffix(self.tz)
}

///|
pub fn PyDate::repr(self : PyDate) -> String {
  "datetime.date(\{self.year}, \{self.month}, \{self.day})"
}

///|
fn time_repr_args(t : PyTime) -> String {
  let mut s = "\{t.hour}, \{t.minute}"
  if t.second != 0 || t.microsecond != 0 {
    s = s + ", \{t.second}"
  }
  if t.microsecond != 0 {
    s = s + ", \{t.microsecond}"
  }
  s
}

///|
pub fn PyTime::repr(self : PyTime) -> String {
  "datetime.time(\{time_repr_args(self)})"
}

///|
pub fn PyDateTime::repr(self : PyDateTime) -> String {
  let d = self.date
  let tz = match self.tz {
    None => ""
    Some(0) => ", tzinfo=datetime.timezone.utc"
    Some(off) =>
      ", tzinfo=datetime.timezone(datetime.timedelta(seconds=\{off}))"
  }
  "datetime.datetime(\{d.year}, \{d.month}, \{d.day}, \{time_repr_args(self.time)}\{tz})"
}

///|
pub fn PyTimeDelta::repr(self : PyTimeDelta) -> String {
  let parts = []
  if self.days != 0L {
    parts.push("days=\{self.days}")
  }
  if self.seconds != 0 {
    parts.push("seconds=\{self.seconds}")
  }
  if self.microseconds != 0 {
    parts.push("microseconds=\{self.microseconds}")
  }
  if parts.is_empty() {
    parts.push("0")
  }
  "datetime.timedelta(" + parts.join(", ") + ")"
}

///|
/// Python `str(timedelta)`.
pub fn PyTimeDelta::py_str(self : PyTimeDelta) -> String {
  let mm = self.seconds / 60
  let ss = self.seconds % 60
  let hh = mm / 60
  let mm = mm % 60
  let mut s = "\{hh}:\{pad(mm, 2)}:\{pad(ss, 2)}"
  if self.days != 0L {
    let plural = if self.days.abs() != 1L { "s" } else { "" }
    s = "\{self.days} day\{plural}, " + s
  }
  if self.microseconds != 0 {
    s = s + "." + pad(self.microseconds, 6)
  }
  s
}

///|
/// `date + timedelta` (only whole days are used, as in Python).
fn PyDate::add_days(self : PyDate, days : Int64) -> PyDate raise PyException {
  from_ordinal(self.toordinal() + days) catch {
    _ => raise PyException("OverflowError", "date value out of range")
  }
}

///|
fn PyDateTime::add_us(
  self : PyDateTime,
  us : Int64,
) -> PyDateTime raise PyException {
  let total = self.total_us() + us
  if total < 0L || total >= 3652059L * 86400000000L {
    raise PyException("OverflowError", "date value out of range")
  }
  datetime_from_us(total, self.tz)
}

///|
/// Python `datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)`.
fn datetime_from_timestamp_utc(ts : Value) -> PyDateTime raise PyException {
  let us = match ts {
    Int(i) => i * 1000000L
    Bool(b) => if b { 1000000L } else { 0L }
    Float(d) => {
      if d.is_nan() || d.is_inf() {
        raise value_error("Invalid value \{float_repr(d)}")
      }
      let secs = d.floor()
      let frac = d - secs
      // round half to even on the microseconds
      let us = round_half_even(frac * 1000000.0)
      secs.to_int64() * 1000000L + us.to_int64()
    }
    _ =>
      raise type_error(
        "'\{ts.type_name()}' object cannot be interpreted as an integer",
      )
  }
  datetime_from_us(us + 62135596800L * 1000000L, Some(0))
}

///|
fn round_half_even(x : Double) -> Double {
  let f = x.floor()
  let diff = x - f
  if diff > 0.5 {
    f + 1.0
  } else if diff < 0.5 {
    f
  } else if f % 2.0 == 0.0 {
    f
  } else {
    f + 1.0
  }
}

// ---- ISO format parsing (Python 3.11+ fromisoformat) ----

///|
fn digits_at(chars : Array[Char], start : Int, count : Int) -> Int? {
  if start + count > chars.length() {
    return None
  }
  let mut v = 0
  for i in start..<(start + count) {
    let c = chars[i]
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  Some(v)
}

///|
fn invalid_iso(s : String) -> PyException {
  value_error("Invalid isoformat string: \{@core.py_repr_str(s)}")
}

///|
/// Parses the date part of an ISO string; returns the date and the number of chars used.
fn parse_iso_date(
  chars : Array[Char],
  s : String,
) -> (PyDate, Int) raise PyException {
  guard digits_at(chars, 0, 4) is Some(year) else { raise invalid_iso(s) }
  if chars.length() >= 5 && chars[4] == '-' {
    if chars.length() >= 6 && chars[5] == 'W' {
      // YYYY-Www[-D]
      guard digits_at(chars, 6, 2) is Some(week) else { raise invalid_iso(s) }
      let (dow, used) = if chars.length() >= 10 && chars[8] == '-' {
        guard digits_at(chars, 9, 1) is Some(d) else { raise invalid_iso(s) }
        (d, 10)
      } else {
        (1, 8)
      }
      return (iso_calendar_date(year, week, dow, s), used)
    }
    guard digits_at(chars, 5, 2) is Some(month) &&
      chars.length() >= 10 &&
      chars[7] == '-' &&
      digits_at(chars, 8, 2) is Some(day) else {
      raise invalid_iso(s)
    }
    (
      check_date(year, month, day) catch {
        PyException(_, m) => raise value_error(m)
      },
      10,
    )
  } else {
    guard digits_at(chars, 4, 2) is Some(month) &&
      digits_at(chars, 6, 2) is Some(day) else {
      raise invalid_iso(s)
    }
    (check_date(year, month, day), 8)
  }
}

///|
fn iso_calendar_date(
  year : Int,
  week : Int,
  dow : Int,
  s : String,
) -> PyDate raise PyException {
  if week < 1 || week > 53 || dow < 1 || dow > 7 {
    raise invalid_iso(s)
  }
  // ordinal of the Monday of ISO week 1
  let jan4 = ordinal(year, 1, 4)
  let week1_monday = jan4 - (jan4 + 6L) % 7L
  from_ordinal(week1_monday + ((week - 1) * 7 + dow - 1).to_int64())
}

///|
/// Parses `HH[:MM[:SS[.ffffff]]]` (or the basic format) followed by an optional UTC
/// offset; returns the time and the offset in seconds.
fn parse_iso_time(
  chars : Array[Char],
  start : Int,
  s : String,
) -> (PyTime, Int?) raise PyException {
  // split off the time zone
  let mut end = chars.length()
  let mut tz : Int? = None
  for i in start..<chars.length() {
    let c = chars[i]
    if c == 'Z' || c == '+' || c == '-' {
      end = i
      if c == 'Z' {
        if i != chars.length() - 1 {
          raise invalid_iso(s)
        }
        tz = Some(0)
      } else {
        let sign = if c == '-' { -1 } else { 1 }
        let rest = chars[i + 1:].to_array()
        let (t, _) = parse_time_fields(rest, 0, s)
        if t.microsecond != 0 {
          raise invalid_iso(s)
        }
        tz = Some(sign * (t.hour * 3600 + t.minute * 60 + t.second))
      }
      break
    }
  }
  let body = chars[start:end].to_array()
  let (t, used) = parse_time_fields(body, 0, s)
  if used != body.length() {
    raise invalid_iso(s)
  }
  (t, tz)
}

///|
fn parse_time_fields(
  chars : Array[Char],
  start : Int,
  s : String,
) -> (PyTime, Int) raise PyException {
  guard digits_at(chars, start, 2) is Some(hour) else { raise invalid_iso(s) }
  let mut pos = start + 2
  let mut minute = 0
  let mut second = 0
  let mut micro = 0
  let extended = pos < chars.length() && chars[pos] == ':'
  fn component(p : Int) -> (Int, Int)? {
    let p = if extended {
      if p < chars.length() && chars[p] == ':' {
        p + 1
      } else {
        return None
      }
    } else {
      p
    }
    match digits_at(chars, p, 2) {
      Some(v) => Some((v, p + 2))
      None => None
    }
  }

  match component(pos) {
    Some((v, p)) => {
      minute = v
      pos = p
      match component(pos) {
        Some((v, p)) => {
          second = v
          pos = p
          if pos < chars.length() && (chars[pos] == '.' || chars[pos] == ',') {
            pos += 1
            let mut n = 0
            let mut frac = 0
            while pos < chars.length() && chars[pos] >= '0' && chars[pos] <= '9' {
              if n < 6 {
                frac = frac * 10 + (chars[pos].to_int() - '0'.to_int())
              }
              n += 1
              pos += 1
            }
            if n == 0 {
              raise invalid_iso(s)
            }
            let mut k = n
            while k < 6 {
              frac = frac * 10
              k += 1
            }
            micro = frac
          }
        }
        None => ()
      }
    }
    None => ()
  }
  (
    check_time(hour, minute, second, micro) catch {
      PyException(_, m) => raise value_error(m)
    },
    pos,
  )
}

///|
/// Python `datetime.date.fromisoformat(s)`.
pub fn date_fromisoformat(v : Value) -> PyDate raise PyException {
  guard v is Str(s) else {
    raise type_error("fromisoformat: argument must be str")
  }
  let chars = s.to_array()
  let (d, used) = parse_iso_date(chars, s)
  if used != chars.length() {
    raise invalid_iso(s)
  }
  d
}

///|
/// Python `datetime.datetime.fromisoformat(s)`.
pub fn datetime_fromisoformat(v : Value) -> PyDateTime raise PyException {
  guard v is Str(s) else {
    raise type_error("fromisoformat: argument must be str")
  }
  let chars = s.to_array()
  let (d, used) = parse_iso_date(chars, s)
  if used == chars.length() {
    return {
      date: d,
      time: { hour: 0, minute: 0, second: 0, microsecond: 0, },
      tz: None,
    }
  }
  // any single separator character
  let (t, tz) = parse_iso_time(chars, used + 1, s)
  { date: d, time: t, tz, }
}

///|
/// Python `datetime.time.fromisoformat(s)`.
pub fn time_fromisoformat(v : Value) -> PyTime raise PyException {
  guard v is Str(s) else {
    raise type_error("fromisoformat: argument must be str")
  }
  let chars = s.to_array()
  let start = if chars.length() > 0 && chars[0] == 'T' { 1 } else { 0 }
  let (t, _) = parse_iso_time(chars, start, s)
  t
}

// ---- strftime / strptime ----

///|
let month_names : Array[String] = [
  "January", "February", "March", "April", "May", "June", "July", "August", "September",
  "October", "November", "December",
]

///|
let day_names : Array[String] = [
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
]

///|
/// Python `datetime.strftime(fmt)` (C locale).
pub fn strftime(dt : PyDateTime, fmt : String) -> String {
  let d = dt.date
  let t = dt.time
  let sb = StringBuilder()
  let chars = fmt.to_array()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c != '%' || i + 1 >= chars.length() {
      sb.write_char(c)
      i += 1
      continue
    }
    let f = chars[i + 1]
    i += 2
    let yday = (d.toordinal() - ordinal(d.year, 1, 1) + 1L).to_int()
    let wday = d.weekday()
    match f {
      'Y' => sb.write_string(d.year.to_string())
      'y' => sb.write_string(pad(d.year % 100, 2))
      'm' => sb.write_string(pad(d.month, 2))
      'd' => sb.write_string(pad(d.day, 2))
      'e' => {
        let s = d.day.to_string()
        sb.write_string(if s.length() < 2 { " " + s } else { s })
      }
      'H' => sb.write_string(pad(t.hour, 2))
      'I' => {
        let h = t.hour % 12
        sb.write_string(pad(if h == 0 { 12 } else { h }, 2))
      }
      'p' => sb.write_string(if t.hour < 12 { "AM" } else { "PM" })
      'M' => sb.write_string(pad(t.minute, 2))
      'S' => sb.write_string(pad(t.second, 2))
      'f' => sb.write_string(pad(t.microsecond, 6))
      'j' => sb.write_string(pad(yday, 3))
      'b' | 'h' => sb.write_string(month_names[d.month - 1].substring(end=3))
      'B' => sb.write_string(month_names[d.month - 1])
      'a' => sb.write_string(day_names[wday].substring(end=3))
      'A' => sb.write_string(day_names[wday])
      'w' => sb.write_string(((wday + 1) % 7).to_string())
      'u' => sb.write_string((wday + 1).to_string())
      'U' => sb.write_string(pad((yday + 6 - (wday + 1) % 7) / 7, 2))
      'W' => sb.write_string(pad((yday + 6 - wday) / 7, 2))
      'F' => sb.write_string(d.isoformat())
      'T' =>
        sb.write_string(
          "\{pad(t.hour, 2)}:\{pad(t.minute, 2)}:\{pad(t.second, 2)}",
        )
      'D' =>
        sb.write_string(
          "\{pad(d.month, 2)}/\{pad(d.day, 2)}/\{pad(d.year % 100, 2)}",
        )
      'z' =>
        match dt.tz {
          None => ()
          Some(off) => {
            let sign = if off < 0 { "-" } else { "+" }
            let o = off.abs()
            sb.write_string(sign + pad(o / 3600, 2) + pad(o / 60 % 60, 2))
          }
        }
      'Z' => if dt.tz is Some(_) { sb.write_string("UTC") }
      '%' => sb.write_char('%')
      _ => {
        sb.write_char('%')
        sb.write_char(f)
      }
    }
  }
  sb.to_string()
}

///|
/// Python `datetime.datetime.strptime(s, fmt)` for the common directives.
pub fn strptime(s : String, fmt : String) -> PyDateTime raise PyException {
  let text = s.to_array()
  let f = fmt.to_array()
  let mut pos = 0
  let mut year = 1900
  let mut month = 1
  let mut day = 1
  let mut hour = 0
  let mut minute = 0
  let mut second = 0
  let mut micro = 0
  let mut pm : Bool? = None
  let mut yday : Int? = None
  let mut tz : Int? = None
  let fail = fn() {
    value_error(
      "time data \{@core.py_repr_str(s)} does not match format \{@core.py_repr_str(fmt)}",
    )
  }
  fn num(max_len : Int) -> Int raise PyException {
    let start = pos
    let mut v = 0
    while pos < text.length() &&
          pos - start < max_len &&
          text[pos] >= '0' &&
          text[pos] <= '9' {
      v = v * 10 + (text[pos].to_int() - '0'.to_int())
      pos += 1
    }
    if pos == start {
      raise fail()
    }
    v
  }

  fn name(names : Array[String], abbrev : Bool) -> Int raise PyException {
    for i, n in names {
      let cand = if abbrev { n.substring(end=3) } else { n }
      let cl = cand.length()
      if pos + cl <= text.length() &&
        @core.py_lower(String::from_array(text[pos:pos + cl].to_array())) ==
        @core.py_lower(cand) {
        pos += cl
        return i
      }
    }
    raise fail()
  }

  let mut i = 0
  while i < f.length() {
    let c = f[i]
    if c == '%' && i + 1 < f.length() {
      let d = f[i + 1]
      i += 2
      match d {
        'Y' => year = num(4)
        'y' => {
          let v = num(2)
          year = if v < 69 { 2000 + v } else { 1900 + v }
        }
        'm' => month = num(2)
        'd' => day = num(2)
        'H' => hour = num(2)
        'I' => hour = num(2)
        'M' => minute = num(2)
        'S' => second = num(2)
        'f' => {
          let start = pos
          let v = num(6)
          let mut k = pos - start
          let mut frac = v
          while k < 6 {
            frac = frac * 10
            k += 1
          }
          micro = frac
        }
        'j' => yday = Some(num(3))
        'p' => {
          let rest = @core.py_lower(String::from_array(text[pos:].to_array()))
          if rest.has_prefix("am") {
            pm = Some(false)
          } else if rest.has_prefix("pm") {
            pm = Some(true)
          } else {
            raise fail()
          }
          pos += 2
        }
        'b' | 'h' => month = name(month_names, true) + 1
        'B' => month = name(month_names, false) + 1
        'a' => ignore(name(day_names, true))
        'A' => ignore(name(day_names, false))
        'z' =>
          if pos < text.length() && text[pos] == 'Z' {
            pos += 1
            tz = Some(0)
          } else {
            guard pos < text.length() && (text[pos] == '+' || text[pos] == '-') else {
              raise fail()
            }
            let sign = if text[pos] == '-' { -1 } else { 1 }
            pos += 1
            let hh = num(2)
            if pos < text.length() && text[pos] == ':' {
              pos += 1
            }
            let mm = num(2)
            tz = Some(sign * (hh * 3600 + mm * 60))
          }
        '%' => {
          guard pos < text.length() && text[pos] == '%' else { raise fail() }
          pos += 1
        }
        _ => raise value_error("'\{d}' is a bad directive in format '\{fmt}'")
      }
    } else if c == ' ' || c == '\t' || c == '\n' {
      // whitespace in the format matches any run of whitespace
      while pos < text.length() &&
            (text[pos] == ' ' || text[pos] == '\t' || text[pos] == '\n') {
        pos += 1
      }
      i += 1
    } else {
      guard pos < text.length() && text[pos] == c else { raise fail() }
      pos += 1
      i += 1
    }
  }
  if pos != text.length() {
    raise value_error(
      "unconverted data remains: \{String::from_array(text[pos:].to_array())}",
    )
  }
  match pm {
    Some(true) => if hour != 12 { hour += 12 }
    Some(false) => if hour == 12 { hour = 0 }
    None => ()
  }
  let date = match yday {
    Some(n) => from_ordinal(ordinal(year, 1, 1) + (n - 1).to_int64())
    None => check_date(year, month, day)
  }
  { date, time: check_time(hour, minute, second, micro), tz, }
}
