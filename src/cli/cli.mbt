// Port of sqlglot/__main__.py: the `python -m sqlglot` command line.
//
// The logic is target independent: `run` takes the arguments and a stdin reader
// and returns what to print, so it can be tested on every backend; the native
// executable in `cmd/sqlglot` only wires it to the process.

///|
/// The version printed by `--version`.
pub let version : String = "0.1.0"

///|
/// The result of a command line invocation.
pub(all) struct CliResult {
  /// Text for standard output.
  stdout : String
  /// Text for standard error.
  stderr : String
  /// The process exit code.
  exit_code : Int
} derive(Debug, Eq)

///|
let prog : String = "sqlglot"

///|
let usage : String = "usage: \{prog} [-h] [--read READ] [--write WRITE] [--identify IDENTIFY] [--no-pretty] [--parse] [--tokenize] [--error-level ERROR_LEVEL] [--version] sql\n"

///|
let help : String =
  $|\{usage}
  $|Transpile SQL
  $|
  $|positional arguments:
  $|  sql                   SQL statement(s) to transpile, or - to parse stdin.
  $|
  $|options:
  $|  -h, --help            show this help message and exit
  $|  --read READ           Dialect to read default is generic
  $|  --write WRITE         Dialect to write default is generic
  $|  --identify IDENTIFY   Whether to quote identifiers (safe, true, false)
  $|  --no-pretty           Compress sql
  $|  --parse               Parse and return the expression tree
  $|  --tokenize            Tokenize and return the tokens list
  $|  --error-level ERROR_LEVEL
  $|                        IGNORE, WARN, RAISE, IMMEDIATE (default)
  $|  --version             Display the SQLGlot version
  $|

///|
/// Parsed command line arguments (the argparse namespace).
priv struct Args {
  mut sql : String?
  mut read : String?
  mut write : String?
  mut identify : String
  mut pretty : Bool
  mut parse : Bool
  mut tokenize : Bool
  mut error_level : String
}

///|
priv suberror ArgError {
  /// argparse error: usage + message on stderr, exit code 2.
  Usage(String)
  /// An action that exits early (--help, --version) with the given stdout.
  Exit(String)
}

///|
/// Long options: (name, takes a value).
let long_options : Array[(String, Bool)] = [
  ("--help", false),
  ("--read", true),
  ("--write", true),
  ("--identify", true),
  ("--no-pretty", false),
  ("--parse", false),
  ("--tokenize", false),
  ("--error-level", true),
  ("--version", false),
]

///|
/// argparse's check for negative-number-like arguments, which are positional.
fn looks_like_negative_number(arg : String) -> Bool {
  let chars = arg.to_array()
  if chars.length() < 2 || chars[0] != '-' {
    return false
  }
  let mut digits = 0
  let mut dots = 0
  for c in chars[1:] {
    if c >= '0' && c <= '9' {
      digits += 1
    } else if c == '.' {
      dots += 1
    } else {
      return false
    }
  }
  digits > 0 && dots <= 1
}

///|
/// Resolves a (possibly abbreviated) long option like argparse's `allow_abbrev`.
fn resolve_option(name : String) -> (String, Bool) raise ArgError {
  for opt in long_options {
    if opt.0 == name {
      return opt
    }
  }
  let matches = long_options.filter(opt => opt.0.has_prefix(name))
  match matches.length() {
    1 => matches[0]
    0 => raise Usage("unrecognized arguments: \{name}")
    _ => {
      let names = matches.map(opt => opt.0).join(", ")
      raise Usage("ambiguous option: \{name} could match \{names}")
    }
  }
}

///|
fn parse_args(argv : Array[String]) -> Args raise ArgError {
  let args : Args = {
    sql: None,
    read: None,
    write: None,
    identify: "safe",
    pretty: true,
    parse: false,
    tokenize: false,
    error_level: "IMMEDIATE",
  }
  let extras : Array[String] = []
  let mut only_positionals = false
  let mut i = 0
  while i < argv.length() {
    let arg = argv[i]
    i += 1
    if only_positionals ||
      arg == "-" ||
      !arg.has_prefix("-") ||
      looks_like_negative_number(arg) {
      if args.sql is None {
        args.sql = Some(arg)
      } else {
        extras.push(arg)
      }
      continue
    }
    if arg == "--" {
      only_positionals = true
      continue
    }
    if arg == "-h" {
      raise Exit(help)
    }
    if !arg.has_prefix("--") {
      extras.push(arg)
      continue
    }
    let (name, inline_value) = match arg.find("=") {
      Some(p) =>
        (
          arg.view(end_offset=p).to_owned(),
          Some(arg.view(start_offset=p + 1).to_owned()),
        )
      None => (arg, None)
    }
    let (opt, takes_value) = resolve_option(name) catch {
      Usage(_) if inline_value is None => {
        extras.push(arg)
        continue
      }
      e => raise e
    }
    let value = if takes_value {
      match inline_value {
        Some(v) => v
        None =>
          if i < argv.length() &&
            (
              !argv[i].has_prefix("-") ||
              argv[i] == "-" ||
              looks_like_negative_number(argv[i])
            ) {
            i += 1
            argv[i - 1]
          } else {
            raise Usage("argument \{opt}: expected one argument")
          }
      }
    } else {
      if inline_value is Some(_) {
        raise Usage(
          "argument \{opt}: ignored explicit argument '\{inline_value.unwrap()}'",
        )
      }
      ""
    }
    match opt {
      "--help" => raise Exit(help)
      "--version" => raise Exit(version + "\n")
      "--read" => args.read = Some(value)
      "--write" => args.write = Some(value)
      "--identify" => args.identify = value
      "--no-pretty" => args.pretty = false
      "--parse" => args.parse = true
      "--tokenize" => args.tokenize = true
      "--error-level" => args.error_level = value
      _ => ()
    }
  }
  if args.sql is None {
    raise Usage("the following arguments are required: sql")
  }
  if !extras.is_empty() {
    raise Usage("unrecognized arguments: \{extras.join(" ")}")
  }
  args
}

///|
/// Python's `repr(token)`.
pub fn token_repr(token : @core.Token) -> String {
  let comments = token.comments.map(@core.py_repr_str).join(", ")
  "<Token token_type: TokenType.\{token.token_type.name()}, text: \{token.text}, line: \{token.line}, col: \{token.col}, start: \{token.start}, end: \{token.end}, comments: [\{comments}]>"
}

///|
/// Python `to_bool` applied to `--identify` ("safe" is passed through).
fn identify_options(identify : String) -> (Bool, String?) {
  if identify == "safe" {
    return (false, Some("safe"))
  }
  match @core.py_lower(identify) {
    "true" | "1" => (true, None)
    "false" | "0" => (false, None)
    _ => (false, Some(identify))
  }
}

///|
priv suberror KeyError {
  KeyError(String)
}

///|
/// `sqlglot.ErrorLevel[name.upper()]`
fn error_level_of(name : String) -> @core.ErrorLevel raise KeyError {
  match @core.py_upper(name) {
    "IGNORE" => Ignore
    "WARN" => Warn
    "RAISE" => Raise
    "IMMEDIATE" => Immediate
    other => raise KeyError(other)
  }
}

///|
/// Runs the command line with `argv` (without the program name). `read_stdin` is
/// called when the SQL argument is `-`.
pub fn run(argv : Array[String], read_stdin : () -> String) -> CliResult {
  let args = parse_args(argv) catch {
    Usage(msg) =>
      return {
        stdout: "",
        stderr: "\{usage}\{prog}: error: \{msg}\n",
        exit_code: 2,
      }
    Exit(out) => return { stdout: out, stderr: "", exit_code: 0, }
  }
  let error_level = error_level_of(args.error_level) catch {
    KeyError(k) =>
      return {
        stdout: "",
        stderr: "KeyError: \{@core.py_repr_str(k)}\n",
        exit_code: 1,
      }
  }
  let objs = execute(args, error_level, read_stdin) catch {
    e => return { stdout: "", stderr: "sqlglot.errors.\{e}\n", exit_code: 1, }
  }
  let out = StringBuilder()
  for obj in objs {
    out.write_string(obj)
    out.write_char('\n')
  }
  { stdout: out.to_string(), stderr: "", exit_code: 0, }
}

///|
fn execute(
  args : Args,
  error_level : @core.ErrorLevel,
  read_stdin : () -> String,
) -> Array[String] raise @core.SqlglotError {
  let sql = match args.sql {
    Some("-") => read_stdin()
    Some(s) => s
    None => ""
  }
  let read = args.read.unwrap_or("")
  if args.parse {
    @sqlglot.parse(sql, read~, error_level~).map(e => {
      match e {
        Some(e) => e.to_s()
        None => "None"
      }
    })
  } else if args.tokenize {
    @core.Dialect::get_or_raise(read).tokenize(sql).map(token_repr)
  } else {
    let (identify, identify_mode) = identify_options(args.identify)
    @sqlglot.transpile(
      sql,
      read~,
      write?=args.write,
      identify~,
      identify_mode?,
      pretty=args.pretty,
      error_level~,
    )
  }
}
