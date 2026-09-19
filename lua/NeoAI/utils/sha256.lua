--- 纯 Lua SHA-256（LuaJIT bit 库）
--- @module NeoAI.utils.sha256
--- 主线程与 `utils.work` 工作线程共用的实现：
--- - `M.hex(s)` 直接在主线程计算；
--- - `M.source` 是同一实现的 Lua 源码字符串，可经 `work.run(fn, ..., M.source)` 传入
---   工作线程（线程内是全新 Lua state，不能 `require` 本模块），线程内 `load(M.source)()`
---   得到同样的 `hex` 函数。
--- 输出为小写十六进制，与 `vim.fn.sha256` 一致（见 test_sha256 交叉校验）。

local SRC = [==[
local band, bxor, bnot, rshift, rol = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.rol
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
return function(msg)
  msg = msg or ""
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  msg = msg .. "\128"
  while #msg % 64 ~= 56 do msg = msg .. "\0" end
  local bits = len * 8
  local hi = math.floor(bits / 4294967296)
  local lo = bits % 4294967296
  msg = msg .. string.char(
    band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255),
    band(rshift(lo, 24), 255), band(rshift(lo, 16), 255), band(rshift(lo, 8), 255), band(lo, 255))
  local w = {}
  for i = 1, #msg, 64 do
    for j = 0, 15 do
      local a, b, c, d = msg:byte(i + j * 4, i + j * 4 + 3)
      w[j] = (a * 16777216 + b * 65536 + c * 256 + d) % 4294967296
    end
    for j = 16, 63 do
      local x = w[j - 15]
      local y = w[j - 2]
      local s0 = bxor(rol(x, 25), rol(x, 14), rshift(x, 3))
      local s1 = bxor(rol(y, 15), rol(y, 13), rshift(y, 10))
      w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % 4294967296
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for j = 0, 63 do
      local S1 = bxor(rol(e, 26), rol(e, 21), rol(e, 7))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[j + 1] + w[j]) % 4294967296
      local S0 = bxor(rol(a, 30), rol(a, 19), rol(a, 10))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = (S0 + maj) % 4294967296
      h, g, f, e = g, f, e, (d + t1) % 4294967296
      d, c, b, a = c, b, a, (t1 + t2) % 4294967296
    end
    h0 = (h0 + a) % 4294967296; h1 = (h1 + b) % 4294967296
    h2 = (h2 + c) % 4294967296; h3 = (h3 + d) % 4294967296
    h4 = (h4 + e) % 4294967296; h5 = (h5 + f) % 4294967296
    h6 = (h6 + g) % 4294967296; h7 = (h7 + h) % 4294967296
  end
  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end
]==]

local impl = assert(load(SRC))()

local M = {}

--- 计算 SHA-256 十六进制摘要
--- @param s string|nil
--- @return string 小写十六进制（64 字符）
function M.hex(s)
  return impl(s or "")
end

--- 实现源码（供工作线程 load 使用）
M.source = SRC

return M
