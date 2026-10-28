-- GitLab line_code hashes the filename with plain SHA-1 (not a Git blob hash).
local bit = require("bit")
local band, bor, bxor, bnot, rol = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol
return function(text)
  local bytes = { text:byte(1, #text) }
  local length = #bytes * 8
  bytes[#bytes + 1] = 128
  while #bytes % 64 ~= 56 do bytes[#bytes + 1] = 0 end
  for i = 7, 0, -1 do bytes[#bytes + 1] = math.floor(length / 2 ^ (i * 8)) % 256 end
  local h = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 }
  local function sum(...) return bit.tobit(({ ... })[1] + select(2, ...)) end
  for offset = 1, #bytes, 64 do
    local w = {}
    for i = 0, 15 do
      local j = offset + i * 4
      w[i] = bor(bit.lshift(bytes[j], 24), bit.lshift(bytes[j + 1], 16),
        bit.lshift(bytes[j + 2], 8), bytes[j + 3])
    end
    for i = 16, 79 do w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1) end
    local a, b, c, d, e = unpack(h)
    for i = 0, 79 do
      local f, k
      if i < 20 then f, k = bor(band(b, c), band(bnot(b), d)), 0x5a827999
      elseif i < 40 then f, k = bxor(b, c, d), 0x6ed9eba1
      elseif i < 60 then f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8f1bbcdc
      else f, k = bxor(b, c, d), 0xca62c1d6 end
      local temp = bit.tobit(rol(a, 5) + f + e + k + w[i])
      e, d, c, b, a = d, c, rol(b, 30), a, temp
    end
    h = { sum(h[1], a), sum(h[2], b), sum(h[3], c), sum(h[4], d), sum(h[5], e) }
  end
  local result = {}
  for _, word in ipairs(h) do
    result[#result + 1] = ("%08x"):format(word < 0 and word + 2 ^ 32 or word)
  end
  return table.concat(result)
end
