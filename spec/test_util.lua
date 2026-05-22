local H    = require("spec.helpers")
local Util = require("caudex.util")

H.section("A. caudex/util.lua")

-- trim
H.eq("trim(nil) -> ''",           Util.trim(nil),   "")
H.eq("trim('  hi  ') -> 'hi'",    Util.trim("  hi  "), "hi")
H.eq("trim('') -> ''",            Util.trim(""),    "")
H.eq("trim('no spaces') -> same", Util.trim("no spaces"), "no spaces")

-- split_csv
H.eq("split_csv(nil) -> {}",          Util.split_csv(nil),           {})
H.eq("split_csv('') -> {}",           Util.split_csv(""),            {})
H.eq("split_csv('a, b , ,c') -> 3",   Util.split_csv("a, b , ,c"),  {"a","b","c"})
H.eq("split_csv('single') -> {single}",Util.split_csv("single"),    {"single"})
H.eq("split_csv('x,y,z') -> 3",       Util.split_csv("x,y,z"),      {"x","y","z"})

-- clone_table
local src  = { a = 1, b = 2 }
local copy = Util.clone_table(src)
H.is_true("clone_table copies keys",   copy.a == 1 and copy.b == 2)
H.is_true("clone_table is new table",  copy ~= src)

-- file_stat / sha256_file
local tmp = os.tmpname()
local f = io.open(tmp, "wb")
f:write("hello world")
f:close()
local size = Util.file_stat(tmp)
H.eq("file_stat returns file size", size, 11)

package.loaded["ffi/sha2"] = {
  sha256 = function(data)
    if data ~= nil then return "oneshot:" .. data end
    local chunks = {}
    return function(chunk)
      if chunk then
        table.insert(chunks, chunk)
        return nil
      end
      return "stream:" .. table.concat(chunks)
    end
  end,
}
H.eq("sha256_file streams file contents", Util.sha256_file(tmp), "stream:hello world")
os.remove(tmp)
package.loaded["ffi/sha2"] = nil
