// Native executable of the `python -m sqlglot` command line (see ../../cli).
// Standard streams are reached through libc directly, so no extra dependency is
// needed.

///|
extern "c" fn c_getchar() -> Int = "getchar"

///|
#borrow(buf)
extern "c" fn c_write(fd : Int, buf : Bytes, len : Int64) -> Int64 = "write"

///|
extern "c" fn c_exit(code : Int) = "exit"

///|
/// Reads standard input to the end and decodes it as UTF-8.
fn read_stdin() -> String {
  let buf = @buffer.new()
  for c = c_getchar(); c >= 0; c = c_getchar() {
    buf.write_byte(c.to_byte())
  }
  let bytes = buf.to_bytes()
  @utf8.decode(bytes) catch {
    _ => @utf8.decode_lossy(bytes)
  }
}

///|
fn write_all(fd : Int, text : String) -> Unit {
  let bytes = @utf8.encode(text)
  let mut offset = 0
  while offset < bytes.length() {
    let rest = bytes[offset:].to_bytes()
    let n = c_write(fd, rest, rest.length().to_int64())
    if n <= 0L {
      break
    }
    offset += n.to_int()
  }
}

///|
fn main {
  let argv = @env.args()
  let args = if argv.is_empty() { [] } else { argv[1:].to_array() }
  let result = @cli.run(args, read_stdin)
  write_all(1, result.stdout)
  write_all(2, result.stderr)
  if result.exit_code != 0 {
    c_exit(result.exit_code)
  }
}
