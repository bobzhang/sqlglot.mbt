// Data ported from sqlglot/time.py (`TIMEZONES`), generated with a Python snippet.

///|
/// Lower-cased IANA time zone names (Python `sqlglot.time.TIMEZONES`).
pub let timezones : @set.Set[String] = @set.Set::from_array([
  "africa/abidjan", "africa/accra", "africa/addis_ababa", "africa/algiers", "africa/asmara",
  "africa/asmera", "africa/bamako", "africa/bangui", "africa/banjul", "africa/bissau",
  "africa/blantyre", "africa/brazzaville", "africa/bujumbura", "africa/cairo", "africa/casablanca",
  "africa/ceuta", "africa/conakry", "africa/dakar", "africa/dar_es_salaam", "africa/djibouti",
  "africa/douala", "africa/el_aaiun", "africa/freetown", "africa/gaborone", "africa/harare",
  "africa/johannesburg", "africa/juba", "africa/kampala", "africa/khartoum", "africa/kigali",
  "africa/kinshasa", "africa/lagos", "africa/libreville", "africa/lome", "africa/luanda",
  "africa/lubumbashi", "africa/lusaka", "africa/malabo", "africa/maputo", "africa/maseru",
  "africa/mbabane", "africa/mogadishu", "africa/monrovia", "africa/nairobi", "africa/ndjamena",
  "africa/niamey", "africa/nouakchott", "africa/ouagadougou", "africa/porto-novo",
  "africa/sao_tome", "africa/timbuktu", "africa/tripoli", "africa/tunis", "africa/windhoek",
  "america/adak", "america/anchorage", "america/anguilla", "america/antigua", "america/araguaina",
  "america/argentina/buenos_aires", "america/argentina/catamarca", "america/argentina/comodrivadavia",
  "america/argentina/cordoba", "america/argentina/jujuy", "america/argentina/la_rioja",
  "america/argentina/mendoza", "america/argentina/rio_gallegos", "america/argentina/salta",
  "america/argentina/san_juan", "america/argentina/san_luis", "america/argentina/tucuman",
  "america/argentina/ushuaia", "america/aruba", "america/asuncion", "america/atikokan",
  "america/atka", "america/bahia", "america/bahia_banderas", "america/barbados",
  "america/belem", "america/belize", "america/blanc-sablon", "america/boa_vista",
  "america/bogota", "america/boise", "america/buenos_aires", "america/cambridge_bay",
  "america/campo_grande", "america/cancun", "america/caracas", "america/catamarca",
  "america/cayenne", "america/cayman", "america/chicago", "america/chihuahua", "america/ciudad_juarez",
  "america/coral_harbour", "america/cordoba", "america/costa_rica", "america/creston",
  "america/cuiaba", "america/curacao", "america/danmarkshavn", "america/dawson",
  "america/dawson_creek", "america/denver", "america/detroit", "america/dominica",
  "america/edmonton", "america/eirunepe", "america/el_salvador", "america/ensenada",
  "america/fort_nelson", "america/fort_wayne", "america/fortaleza", "america/glace_bay",
  "america/godthab", "america/goose_bay", "america/grand_turk", "america/grenada",
  "america/guadeloupe", "america/guatemala", "america/guayaquil", "america/guyana",
  "america/halifax", "america/havana", "america/hermosillo", "america/indiana/indianapolis",
  "america/indiana/knox", "america/indiana/marengo", "america/indiana/petersburg",
  "america/indiana/tell_city", "america/indiana/vevay", "america/indiana/vincennes",
  "america/indiana/winamac", "america/indianapolis", "america/inuvik", "america/iqaluit",
  "america/jamaica", "america/jujuy", "america/juneau", "america/kentucky/louisville",
  "america/kentucky/monticello", "america/knox_in", "america/kralendijk", "america/la_paz",
  "america/lima", "america/los_angeles", "america/louisville", "america/lower_princes",
  "america/maceio", "america/managua", "america/manaus", "america/marigot", "america/martinique",
  "america/matamoros", "america/mazatlan", "america/mendoza", "america/menominee",
  "america/merida", "america/metlakatla", "america/mexico_city", "america/miquelon",
  "america/moncton", "america/monterrey", "america/montevideo", "america/montreal",
  "america/montserrat", "america/nassau", "america/new_york", "america/nipigon",
  "america/nome", "america/noronha", "america/north_dakota/beulah", "america/north_dakota/center",
  "america/north_dakota/new_salem", "america/nuuk", "america/ojinaga", "america/panama",
  "america/pangnirtung", "america/paramaribo", "america/phoenix", "america/port-au-prince",
  "america/port_of_spain", "america/porto_acre", "america/porto_velho", "america/puerto_rico",
  "america/punta_arenas", "america/rainy_river", "america/rankin_inlet", "america/recife",
  "america/regina", "america/resolute", "america/rio_branco", "america/rosario",
  "america/santa_isabel", "america/santarem", "america/santiago", "america/santo_domingo",
  "america/sao_paulo", "america/scoresbysund", "america/shiprock", "america/sitka",
  "america/st_barthelemy", "america/st_johns", "america/st_kitts", "america/st_lucia",
  "america/st_thomas", "america/st_vincent", "america/swift_current", "america/tegucigalpa",
  "america/thule", "america/thunder_bay", "america/tijuana", "america/toronto", "america/tortola",
  "america/vancouver", "america/virgin", "america/whitehorse", "america/winnipeg",
  "america/yakutat", "america/yellowknife", "antarctica/casey", "antarctica/davis",
  "antarctica/dumontdurville", "antarctica/macquarie", "antarctica/mawson", "antarctica/mcmurdo",
  "antarctica/palmer", "antarctica/rothera", "antarctica/south_pole", "antarctica/syowa",
  "antarctica/troll", "antarctica/vostok", "arctic/longyearbyen", "asia/aden", "asia/almaty",
  "asia/amman", "asia/anadyr", "asia/aqtau", "asia/aqtobe", "asia/ashgabat", "asia/ashkhabad",
  "asia/atyrau", "asia/baghdad", "asia/bahrain", "asia/baku", "asia/bangkok", "asia/barnaul",
  "asia/beirut", "asia/bishkek", "asia/brunei", "asia/calcutta", "asia/chita", "asia/choibalsan",
  "asia/chongqing", "asia/chungking", "asia/colombo", "asia/dacca", "asia/damascus",
  "asia/dhaka", "asia/dili", "asia/dubai", "asia/dushanbe", "asia/famagusta", "asia/gaza",
  "asia/harbin", "asia/hebron", "asia/ho_chi_minh", "asia/hong_kong", "asia/hovd",
  "asia/irkutsk", "asia/istanbul", "asia/jakarta", "asia/jayapura", "asia/jerusalem",
  "asia/kabul", "asia/kamchatka", "asia/karachi", "asia/kashgar", "asia/kathmandu",
  "asia/katmandu", "asia/khandyga", "asia/kolkata", "asia/krasnoyarsk", "asia/kuala_lumpur",
  "asia/kuching", "asia/kuwait", "asia/macao", "asia/macau", "asia/magadan", "asia/makassar",
  "asia/manila", "asia/muscat", "asia/nicosia", "asia/novokuznetsk", "asia/novosibirsk",
  "asia/omsk", "asia/oral", "asia/phnom_penh", "asia/pontianak", "asia/pyongyang",
  "asia/qatar", "asia/qostanay", "asia/qyzylorda", "asia/rangoon", "asia/riyadh",
  "asia/saigon", "asia/sakhalin", "asia/samarkand", "asia/seoul", "asia/shanghai",
  "asia/singapore", "asia/srednekolymsk", "asia/taipei", "asia/tashkent", "asia/tbilisi",
  "asia/tehran", "asia/tel_aviv", "asia/thimbu", "asia/thimphu", "asia/tokyo", "asia/tomsk",
  "asia/ujung_pandang", "asia/ulaanbaatar", "asia/ulan_bator", "asia/urumqi", "asia/ust-nera",
  "asia/vientiane", "asia/vladivostok", "asia/yakutsk", "asia/yangon", "asia/yekaterinburg",
  "asia/yerevan", "atlantic/azores", "atlantic/bermuda", "atlantic/canary", "atlantic/cape_verde",
  "atlantic/faeroe", "atlantic/faroe", "atlantic/jan_mayen", "atlantic/madeira",
  "atlantic/reykjavik", "atlantic/south_georgia", "atlantic/st_helena", "atlantic/stanley",
  "australia/act", "australia/adelaide", "australia/brisbane", "australia/broken_hill",
  "australia/canberra", "australia/currie", "australia/darwin", "australia/eucla",
  "australia/hobart", "australia/lhi", "australia/lindeman", "australia/lord_howe",
  "australia/melbourne", "australia/north", "australia/nsw", "australia/perth", "australia/queensland",
  "australia/south", "australia/sydney", "australia/tasmania", "australia/victoria",
  "australia/west", "australia/yancowinna", "brazil/acre", "brazil/denoronha", "brazil/east",
  "brazil/west", "canada/atlantic", "canada/central", "canada/eastern", "canada/mountain",
  "canada/newfoundland", "canada/pacific", "canada/saskatchewan", "canada/yukon",
  "cet", "chile/continental", "chile/easterisland", "cst6cdt", "cuba", "eet", "egypt",
  "eire", "est", "est5edt", "etc/gmt", "etc/gmt+0", "etc/gmt+1", "etc/gmt+10", "etc/gmt+11",
  "etc/gmt+12", "etc/gmt+2", "etc/gmt+3", "etc/gmt+4", "etc/gmt+5", "etc/gmt+6",
  "etc/gmt+7", "etc/gmt+8", "etc/gmt+9", "etc/gmt-0", "etc/gmt-1", "etc/gmt-10",
  "etc/gmt-11", "etc/gmt-12", "etc/gmt-13", "etc/gmt-14", "etc/gmt-2", "etc/gmt-3",
  "etc/gmt-4", "etc/gmt-5", "etc/gmt-6", "etc/gmt-7", "etc/gmt-8", "etc/gmt-9", "etc/gmt0",
  "etc/greenwich", "etc/uct", "etc/universal", "etc/utc", "etc/zulu", "europe/amsterdam",
  "europe/andorra", "europe/astrakhan", "europe/athens", "europe/belfast", "europe/belgrade",
  "europe/berlin", "europe/bratislava", "europe/brussels", "europe/bucharest", "europe/budapest",
  "europe/busingen", "europe/chisinau", "europe/copenhagen", "europe/dublin", "europe/gibraltar",
  "europe/guernsey", "europe/helsinki", "europe/isle_of_man", "europe/istanbul",
  "europe/jersey", "europe/kaliningrad", "europe/kiev", "europe/kirov", "europe/kyiv",
  "europe/lisbon", "europe/ljubljana", "europe/london", "europe/luxembourg", "europe/madrid",
  "europe/malta", "europe/mariehamn", "europe/minsk", "europe/monaco", "europe/moscow",
  "europe/nicosia", "europe/oslo", "europe/paris", "europe/podgorica", "europe/prague",
  "europe/riga", "europe/rome", "europe/samara", "europe/san_marino", "europe/sarajevo",
  "europe/saratov", "europe/simferopol", "europe/skopje", "europe/sofia", "europe/stockholm",
  "europe/tallinn", "europe/tirane", "europe/tiraspol", "europe/ulyanovsk", "europe/uzhgorod",
  "europe/vaduz", "europe/vatican", "europe/vienna", "europe/vilnius", "europe/volgograd",
  "europe/warsaw", "europe/zagreb", "europe/zaporozhye", "europe/zurich", "gb", "gb-eire",
  "gmt", "gmt+0", "gmt-0", "gmt0", "greenwich", "hongkong", "hst", "iceland", "indian/antananarivo",
  "indian/chagos", "indian/christmas", "indian/cocos", "indian/comoro", "indian/kerguelen",
  "indian/mahe", "indian/maldives", "indian/mauritius", "indian/mayotte", "indian/reunion",
  "iran", "israel", "jamaica", "japan", "kwajalein", "libya", "met", "mexico/bajanorte",
  "mexico/bajasur", "mexico/general", "mst", "mst7mdt", "navajo", "nz", "nz-chat",
  "pacific/apia", "pacific/auckland", "pacific/bougainville", "pacific/chatham",
  "pacific/chuuk", "pacific/easter", "pacific/efate", "pacific/enderbury", "pacific/fakaofo",
  "pacific/fiji", "pacific/funafuti", "pacific/galapagos", "pacific/gambier", "pacific/guadalcanal",
  "pacific/guam", "pacific/honolulu", "pacific/johnston", "pacific/kanton", "pacific/kiritimati",
  "pacific/kosrae", "pacific/kwajalein", "pacific/majuro", "pacific/marquesas", "pacific/midway",
  "pacific/nauru", "pacific/niue", "pacific/norfolk", "pacific/noumea", "pacific/pago_pago",
  "pacific/palau", "pacific/pitcairn", "pacific/pohnpei", "pacific/ponape", "pacific/port_moresby",
  "pacific/rarotonga", "pacific/saipan", "pacific/samoa", "pacific/tahiti", "pacific/tarawa",
  "pacific/tongatapu", "pacific/truk", "pacific/wake", "pacific/wallis", "pacific/yap",
  "poland", "portugal", "prc", "pst8pdt", "roc", "rok", "singapore", "turkey", "uct",
  "universal", "us/alaska", "us/aleutian", "us/arizona", "us/central", "us/east-indiana",
  "us/eastern", "us/hawaii", "us/indiana-starke", "us/michigan", "us/mountain", "us/pacific",
  "us/samoa", "utc", "w-su", "wet", "zulu",
])

///|
fn iso_digits(chars : Array[Char], start : Int, n : Int) -> Int? {
  if start < 0 || start + n > chars.length() {
    return None
  }
  let mut v = 0
  for i in start..<(start + n) {
    let c = chars[i]
    if !(c >= '0' && c <= '9') {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  Some(v)
}

///|
fn iso_is_leap(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
fn iso_days_in_month(year : Int, month : Int) -> Int {
  match month {
    2 => if iso_is_leap(year) { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
}

///|
/// Validates the date component of an ISO-8601 string, returning its length.
fn iso_date_len(chars : Array[Char]) -> Int? {
  let n = chars.length()
  guard iso_digits(chars, 0, 4) is Some(year) && year >= 1 else { return None }
  if n >= 5 && chars[4] == '-' {
    if n >= 6 && chars[5] == 'W' {
      guard iso_digits(chars, 6, 2) is Some(week) && week >= 1 && week <= 53 else {
        return None
      }
      if n >= 10 && chars[8] == '-' {
        guard iso_digits(chars, 9, 1) is Some(d) && d >= 1 && d <= 7 else {
          return None
        }
        return Some(10)
      }
      return Some(8)
    }
    guard iso_digits(chars, 5, 2) is Some(month) &&
      month >= 1 &&
      month <= 12 &&
      n >= 10 &&
      chars[7] == '-' &&
      iso_digits(chars, 8, 2) is Some(day) &&
      day >= 1 &&
      day <= iso_days_in_month(year, month) else {
      return None
    }
    return Some(10)
  }
  if n >= 5 && chars[4] == 'W' {
    guard iso_digits(chars, 5, 2) is Some(week) && week >= 1 && week <= 53 else {
      return None
    }
    if n >= 8 && chars[7] >= '0' && chars[7] <= '9' {
      guard iso_digits(chars, 7, 1) is Some(d) && d >= 1 && d <= 7 else {
        return None
      }
      return Some(8)
    }
    return Some(7)
  }
  guard iso_digits(chars, 4, 2) is Some(month) &&
    month >= 1 &&
    month <= 12 &&
    iso_digits(chars, 6, 2) is Some(day) &&
    day >= 1 &&
    day <= iso_days_in_month(year, month) else {
    return None
  }
  Some(8)
}

///|
/// Parses `HH[:MM[:SS[.ffffff]]]` (or the compact form) starting at `start` and ending
/// at `end`. Returns the fractional digits (possibly empty) if valid.
fn iso_time_fraction(
  chars : Array[Char],
  start : Int,
  end : Int,
  max_hour : Int,
) -> String? {
  let mut i = start
  guard iso_digits(chars, i, 2) is Some(hh) && hh <= max_hour else {
    return None
  }
  i += 2
  let mut has_colon : Bool? = None
  let mut components = 1
  while i < end && components < 3 {
    let c = chars[i]
    if c == ':' {
      if has_colon is Some(false) {
        return None
      }
      has_colon = Some(true)
      i += 1
    } else if c >= '0' && c <= '9' {
      if has_colon is Some(true) {
        return None
      }
      has_colon = Some(false)
    } else {
      break
    }
    guard iso_digits(chars, i, 2) is Some(v) && v <= 59 else { return None }
    i += 2
    components += 1
  }
  if i == end {
    return Some("")
  }
  if components < 3 || !(chars[i] == '.' || chars[i] == ',') {
    return None
  }
  i += 1
  if i >= end {
    return None
  }
  let sb = StringBuilder()
  while i < end {
    let c = chars[i]
    if !(c >= '0' && c <= '9') {
      return None
    }
    sb.write_char(c)
    i += 1
  }
  Some(sb.to_string())
}

///|
/// Port of `sqlglot.time.subsecond_precision`: given an ISO-8601 timestamp literal, e.g.
/// '2023-01-01 12:13:14.123456+00:00', returns its subsecond precision (0, 3 or 6).
/// Mirrors Python's `datetime.fromisoformat`; invalid literals yield 0.
pub fn subsecond_precision(timestamp_literal : String) -> Int {
  let chars = timestamp_literal.to_array()
  let n = chars.length()
  guard iso_date_len(chars) is Some(date_len) else { return 0 }
  if n <= date_len + 1 {
    return 0
  }
  // The time part starts after a single separator character.
  let time_start = date_len + 1
  let mut tz_start = n
  for i in time_start..<n {
    if chars[i] == '+' || chars[i] == '-' || chars[i] == 'Z' {
      tz_start = i
      break
    }
  }
  guard iso_time_fraction(chars, time_start, tz_start, 23) is Some(fraction) else {
    return 0
  }
  if tz_start < n {
    if chars[tz_start] == 'Z' {
      if tz_start + 1 != n {
        return 0
      }
    } else if tz_start + 1 >= n ||
      iso_time_fraction(chars, tz_start + 1, n, 23) is None {
      return 0
    }
  }
  let digits = if fraction.length() > 6 {
    fraction.view(end_offset=6).to_owned()
  } else {
    fraction + "0".repeat(6 - fraction.length())
  }
  let mut count = 6
  while count > 0 && digits.get_char(count - 1) == Some('0') {
    count -= 1
  }
  if count > 3 {
    6
  } else if count > 0 {
    3
  } else {
    0
  }
}
