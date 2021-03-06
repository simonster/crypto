immutable AES_cipher_params{T<:Unsigned}
  bits::T # Cipher key length, bits
  nk::T # Number of 32-bit words, cipher key
  nb::T # Number of columns in State
  nr::T # Number of rounds
  block_size::T # byte length
  block_x::T # block dimensions X
  block_y::T # block dimensions Y
end

function aes_get_cipher_params(key::Vector{Uint8})
  bits::Unsigned = 8 * length(key)
  @assert bits in (128, 192, 256)
  nk::Unsigned = bits / 32
  nb::Unsigned = 4
  nr::Unsigned = bits / 32 + 6
  block_size::Unsigned = 16
  block_x::Unsigned = 4
  block_y::Unsigned = 4
  return AES_cipher_params(bits, nk, nb, nr, block_size, block_x, block_y)
end

function polynomial_degree(p::Unsigned, i::Integer)
  while i > -1
    if p & (0x0000001 << i) != 0
      return i
    end
    i -= 1
  end
  return -1
end

function polynomial_degree(p::Uint8)
  polynomial_degree(p, 7)
end

function polynomial_degree(p::Uint16)
  i = 15
  polynomial_degree(p, 15)
end

function gf_div(x::Unsigned, d::Unsigned)
  r = UInt16(x)
  d = UInt16(d)
  q::Uint16 = 0x0
  r_deg = polynomial_degree(r)
  d_deg = polynomial_degree(d)
  shift = r - d

  while r_deg >= d_deg
    shift = r_deg - d_deg
    q |= UInt16(0x1) << shift
    r = r $ (d << (shift))
    r_deg = polynomial_degree(r)
  end
  q, r
end

function gf_modulo(x::Unsigned)
  q, r = gf_div(x, 0x011b)
  r
end

function xtime(x::Uint8)
  (x << 1) $ (0x1b * (x & 0x80 == 0x80))
end

function xtime_recursive(x::Uint8, i::Integer)
  while i > 0
    i -= 1
    x = xtime(x)
  end
  x
end

@inline function _gf_mult(x::Uint8, y::Uint8)
  s::Uint8 = 0x0
  if x >= y
  while y > 0
    s = ifelse(y % 2 == 1, s $ x, s)
    y >>>= 1
    x = xtime(x)
    end
  else
    while x > 0
    s = ifelse(x % 2 == 1, s $ y, s)
    x >>>= 1
    y = xtime(y)
    end
  end
  s
end

# Comment this out and rename _gf_mult to gf_mult to avoid table lookup
const gf_mult_lookup = [_gf_mult(x, y) for x = 0x00:0xff, y = 0x00:0xff]
gf_mult(x::Uint8, y::Uint8) = gf_mult_lookup[x+1, y+1]

function mult_poly(x::Unsigned, y::Unsigned)
  shifts = Array(Any, 0)
  p::Uint64 = 0
  for i = 0:polynomial_degree(UInt16(y))
    if y & (1 << i) != 0
      push!(shifts, i)
    end
  end

  for i = 1:length(shifts)
    p $= UInt64(x) << shifts[i]
  end
  p
end

function gf_mult_long(x::Unsigned, y::Unsigned)
  p = mult_poly(x, y)
  gf_modulo(p)
end

function gf_mult_inv(a::Unsigned, p::Unsigned = 0x011b)
  u::Unsigned = p
  u_next::Unsigned = a
  v::Unsigned = 0
  v_next::Unsigned = 1
  q = 0
  r = 0

  while u_next != 0
    q, r = gf_div(u, u_next)
    (u, u_next) = (u_next, u $ mult_poly(q, u_next))
    (v, v_next) = (v_next, v $ mult_poly(q, v_next))
  end
  v
end

function gf_mult_inv_by_force(x::Uint8)
  for i = 0x00:0xff
    if gf_mult(x, i) == 0x01
      return i
    end
  end
end

function get_bit_of_byte(byte::Unsigned, bit::Unsigned)
  return byte & (one(Uint64) << bit) == 0x0 ? 0 : 1
end

function bit_array(byte::Unsigned)
  len = sizeof(byte) * 8
  arr = Array(Uint8, len, 1)
  for i::Unsigned = 1:len
    arr[i, 1] = get_bit_of_byte(byte, i - 1)
  end
  arr
end

function bit_vector(byte::Unsigned)
  len = sizeof(byte) * 8
  arr = Array(Uint8, len)
  for i::Unsigned = 1:len
    arr[i] = get_bit_of_byte(byte, i - 1)
  end
  arr
end

function bit_vector_to_byte(bits::Vector{Uint8})
  b::Uint8 = 0x0
  for i = 1:8
    b |= bits[i] << (i - 1)
  end
  b
end

function subbytes_affine_transform(b::Uint8)
  b_bits = bit_vector(b)
  o_bits = bit_vector(0x00)
  bits_addend = bit_vector(0x63)

  for i::Unsigned = 1:8
    o_bits[i] = b_bits[i] $ b_bits[mod1(i+4,8)] $ b_bits[mod1(i+5,8)] $ b_bits[mod1(i+6,8)] $ b_bits[mod1(i+7,8)] $ bits_addend[i]
  end
  bit_vector_to_byte(o_bits)
end

function gen_s_box(s::Uint8)
  s::Uint8 = gf_mult_inv(s)
  subbytes_affine_transform(s)
end

function gen_s_box_inv()
  box = Array(Uint8, 256)
  for i in 0:255
    s = s_box[i+1]
    box[s+1] = i
  end
  box
end

const s_box = [gen_s_box(s) for s::Uint8 = 0:255]
const s_box_inv = gen_s_box_inv()

function sub_bytes!(state::Array{Uint8})
  for i = 1:4
    @simd for j = 1:4
      @inbounds state[i, j] = s_box[1+state[i, j]]
    end
  end
end

function sub_bytes_inv!(state::Array{Uint8})
  for i = 1:4
    for j = 1:4
      state[i, j] = s_box_inv[1+state[i, j]]
    end
  end
end

function shift_rows!(state::Array{Uint8})
  state[2, 1], state[2, 2], state[2, 3], state[2, 4] = (state[2, 2], state[2, 3], state[2, 4], state[2, 1])
  state[3, 1], state[3, 2], state[3, 3], state[3, 4] = (state[3, 3], state[3, 4], state[3, 1], state[3, 2])
  state[4, 1], state[4, 2], state[4, 3], state[4, 4] = (state[4, 4], state[4, 1], state[4, 2], state[4, 3])
end

function shift_rows_inv!(state::Array{Uint8})
  row = Array(Uint8, 4)
  for i = 2:4
    for j in 0:3
      row[mod1(j+i,4)] = state[i, j+1]
    end
    state[i, :] = row
  end
end

function mix_columns!(state::Array{Uint8})
  for j = 1:4
    @inbounds (state[1,j], state[2,j], state[3,j], state[4, j]) = (
      gf_mult(0x02, state[1,j]) $ gf_mult(0x03, state[2,j]) $ state[3,j] $ state[4,j],
      state[1,j] $ gf_mult(0x02, state[2,j]) $ gf_mult(0x03, state[3,j]) $ state[4,j],
      state[1,j] $ state[2,j] $ gf_mult(0x02, state[3,j]) $ gf_mult(0x03, state[4,j]),
      gf_mult(0x03, state[1,j]) $ state[2,j] $ state[3,j] $ gf_mult(0x02, state[4,j])
    )
  end
end

function mix_columns_inv!(state::Array{Uint8})
  temp::Array{Uint8, 2} = Array(Uint8, 4, 1)
  @simd for j = 1:4
    temp[1,1] = gf_mult(0x0e, state[1,j]) $ gf_mult(0x0b, state[2,j]) $ gf_mult(0x0d, state[3,j]) $ gf_mult(0x09, state[4,j])
    temp[2,1] = gf_mult(0x09, state[1,j]) $ gf_mult(0x0e, state[2,j]) $ gf_mult(0x0b, state[3,j]) $ gf_mult(0x0d, state[4,j])
    temp[3,1] = gf_mult(0x0d, state[1,j]) $ gf_mult(0x09, state[2,j]) $ gf_mult(0x0e, state[3,j]) $ gf_mult(0x0b, state[4,j])
    temp[4,1] = gf_mult(0x0b, state[1,j]) $ gf_mult(0x0d, state[2,j]) $ gf_mult(0x09, state[3,j]) $ gf_mult(0x0e, state[4,j])
    state[:,j] = temp
  end
end

function add_words(a::Uint8, b::Uint8)
  a $ b
end

@vectorize_2arg Uint8 add_words

function mult_words(A::Vector{Uint8}, B::Vector{Uint8})
  d::Vector{Uint8} = [0, 0, 0, 0]
  d[1] = gf_mult(a[1], b[1]) $ gf_mult(a[4], b[2]) $ gf_mult(a[3], b[3]) $ gf_mult(a[2], b[4])
  d[2] = gf_mult(a[2], b[1]) $ gf_mult(a[1], b[2]) $ gf_mult(a[4], b[3]) $ gf_mult(a[3], b[4])
  d[3] = gf_mult(a[3], b[1]) $ gf_mult(a[2], b[2]) $ gf_mult(a[1], b[3]) $ gf_mult(a[4], b[4])
  d[4] = gf_mult(a[4], b[1]) $ gf_mult(a[3], b[2]) $ gf_mult(a[2], b[3]) $ gf_mult(a[1], b[4])
  return d
end

function add_round_key!(state::Array{Uint8}, words::Array{Uint8}, blk::Integer)
  for j = 1:4
    @simd for i = 1:4
      @inbounds state[i,j] $= words[i,j,blk]
    end
  end
end

function sub_word!(word::Vector{Uint8})
  for i = 1:4
    word[i] = s_box[1 + word[i]]
  end
end

function rot_word!(word::Vector{Uint8})
  b = word[1]
  for i = 1:3
    word[i] = word[i + 1]
  end
  word[4] = b
end

function rcon_xor!(word::Vector{Uint8}, i::Uint8)
  word[1] = word[1] $ xtime_recursive(0x01, i-1)
end

function gen_key_schedule(key::Vector{Uint8}, params::AES_cipher_params)
  i = 0
  key_block = Array(Uint8, 4, params.nb * (1 + params.nr))

  while i < params.nk
    key_block[:, i+1] = key[4i+1:4(i+1)]
    i += 1
  end

  while i < params.nb * (1 + params.nr)
    key_ = key_block[:,i]
    if i % params.nk == 0
      rot_word!(key_)
      sub_word!(key_)
      rcon_xor!(key_, UInt8(i / params.nk))
    elseif (params.bits == 256) && (i % params.nk == 4)
      sub_word!(key_)
    end
    key_block[:,i+1] = add_words(key_block[:,i - params.nk + 1], key_)
    i += 1
  end
  key_block
end

function rijndael(state::Array{Uint8}, key_block::Array{Uint8}, params::AES_cipher_params)
  add_round_key!(state, key_block, 1)

  i = 2
  while i <= params.nr
    sub_bytes!(state)
    shift_rows!(state)
    mix_columns!(state)
    add_round_key!(state, key_block, i)
    i += 1
  end

  sub_bytes!(state)
  shift_rows!(state)
  add_round_key!(state, key_block, i)
  state
end

function rijndael_inverse(state::Array{Uint8}, key_block::Array{Uint8}, params::AES_cipher_params)
  i = params.nr + 1
  add_round_key!(state, key_block, i)

  while i > 2
    i -= 1
    shift_rows_inv!(state)
    sub_bytes_inv!(state)
    add_round_key!(state, key_block, i)
    mix_columns_inv!(state)
  end
  i -= 1
  shift_rows_inv!(state)
  sub_bytes_inv!(state)
  add_round_key!(state, key_block, i)
  state
end

function pad_pkcs7!(plain_text::Vector{Uint8}, block_size::Unsigned)
  pad_length::Uint8 = length(plain_text) % block_size
  while length(plain_text) % block_size != 0
    push!(plain_text, pad_length)
  end
end

function apply_ECB_mode!(cipher::Function, plain_text::Vector{Uint8}, key::Vector{Uint8})
  params = aes_get_cipher_params(key)
  key_block = gen_key_schedule(key, params)
  key_block = reshape(key_block, 4, 4, Int(params.nr + 1))
  pad_pkcs7!(plain_text, params.block_size)

  num_blocks::Unsigned = length(plain_text) / params.block_size
  input = reshape(plain_text, Int(params.block_y), Int(params.block_x), Int(num_blocks))
  for k in 1:num_blocks
    input[:,:,k] = cipher(input[:,:,k], key_block, params)
  end
end

function test_rijndael()
  #plaintext_verify = hex2bytes("3243f6a8885a308d313198a2e0370734")
  #key_128_verify = hex2bytes("2b7e151628aed2a6abf7158809cf4f3c")
  plaintext = hex2bytes("00112233445566778899aabbccddeeff")
  key_128 = hex2bytes("000102030405060708090a0b0c0d0e0f")
  key_192 = hex2bytes("000102030405060708090a0b0c0d0e0f1011121314151617")
  key_256 = hex2bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

  apply_ECB_mode!(rijndael, plaintext, key_128)
  @assert plaintext == hex2bytes("69c4e0d86a7b0430d8cdb78070b4c55a")
  apply_ECB_mode!(rijndael_inverse, plaintext, key_128)
  @assert plaintext == hex2bytes("00112233445566778899aabbccddeeff")

  apply_ECB_mode!(rijndael, plaintext, key_192)
  @assert plaintext == hex2bytes("dda97ca4864cdfe06eaf70a0ec0d7191")
  apply_ECB_mode!(rijndael_inverse, plaintext, key_192)
  @assert plaintext == hex2bytes("00112233445566778899aabbccddeeff")

  apply_ECB_mode!(rijndael, plaintext, key_256)
  @assert plaintext == hex2bytes("8ea2b7ca516745bfeafc49904b496089")
  apply_ECB_mode!(rijndael_inverse, plaintext, key_256)
  @assert plaintext == hex2bytes("00112233445566778899aabbccddeeff")

  print("Rijndael tests PASSED")
end

a = test_rijndael()

function detect_ECB_mode(cipher_text::Vector{Uint8}, block_size::Unsigned)
  #chunk cipher_text into blocks of equal length and see if any are the same
  @assert length(cipher_text) % block_size == 0
  num_blocks::Unsigned = (length(cipher_text) - (length(cipher_text) % block_size)) / block_size
  cipher_text = cipher_text[1:num_blocks*block_size]
  cipher_text = reshape(cipher_text, int(block_size), int(num_blocks))
  s = Set()
  for i = 1:num_blocks
    push!(s, cipher_text[:,i])
  end
  if length(s) < num_blocks
    return true
  end
  return false
end


# in = hex2bytes("00112233445566778899aabbccddeeff")
# key = hex2bytes("000102030405060708090a0b0c0d0e0f")
# prm = aes_get_cipher_params(key)
# keys = gen_key_schedule(key, prm)
# keyr = reshape(keys, 4, 4, 11)

# inr = reshape(in, 4, 4)
# @profile (for i = 1:10000; rijndael(inr, keyr, prm); end)
# @time rijndael(inr, keyr, prm)

# input = map(uint8, collect(readall(instream)))
# @profile (for i = 1:100; apply_ECB_mode!(rijndael, input, key); end)

# Profile.print()
# Profile.clear()


function test_detect_ECB_mode()
  infile = open("8.txt", "r")
  strs = readlines(infile)
  strs = map(chomp, strs)
  strs = map(hex2bytes, strs)
  for i = 1:length(strs)
    if detect_ECB_mode(strs[i], uint(16))
      println("possible ECB block cipher encryption: ", i, strs[i])
    end
  end
end
