-- Vanilla Gen 3 (FireRed / LeafGreen) raw Flash 128 KiB <-> engine save table.
-- Companion to GenSave.lua (Gen 1) and Gen2Save.lua (Gen 2).
--
-- Pure Lua, no love.* at require time.

local bit = require("bit")
local TextIR = require("src.core.game3.scripting.text_ir")
local ItemsData = require("src.core.game3.items_data")
local MapCatalog = require("src.import.gba.map_catalog")
local Schema = require("src.core.game3.save_schema_firered")

local Gen3Save = {}

Gen3Save.SAVE_SIZE = 131072         -- 128 KiB Flash
Gen3Save.SECTOR_SIZE = 4096         -- 4 KiB per sector
Gen3Save.SECTOR_DATA_SIZE = 3968
Gen3Save.SECTORS_PER_SLOT = 14
Gen3Save.NUM_SLOTS = 2
Gen3Save.SECTOR_SIGNATURE = 0x08012025

Gen3Save.BOX_CAPACITY = 30
Gen3Save.TOTAL_BOXES = 14
Gen3Save.BOX_MON_STRUCT = 80
Gen3Save.PARTY_MON_STRUCT = 100
Gen3Save.PARTY_CAPACITY = 6
Gen3Save.NUM_SPECIES = 386

-- Payload size for each sector ID (0 to 13) in FireRed / LeafGreen.
local SECTOR_SIZES = {
  [0]  = 3884, -- Sector 0:  SaveBlock2
  [1]  = 3968, -- Sector 1:  SaveBlock1 chunk 0
  [2]  = 3968, -- Sector 2:  SaveBlock1 chunk 1
  [3]  = 3968, -- Sector 3:  SaveBlock1 chunk 2
  [4]  = 3848, -- Sector 4:  SaveBlock1 chunk 3
  [5]  = 3968, -- Sector 5:  PokemonStorage chunk 0
  [6]  = 3968, -- Sector 6:  PokemonStorage chunk 1
  [7]  = 3968, -- Sector 7:  PokemonStorage chunk 2
  [8]  = 3968, -- Sector 8:  PokemonStorage chunk 3
  [9]  = 3968, -- Sector 9:  PokemonStorage chunk 4
  [10] = 3968, -- Sector 10: PokemonStorage chunk 5
  [11] = 3968, -- Sector 11: PokemonStorage chunk 6
  [12] = 3968, -- Sector 12: PokemonStorage chunk 7
  [13] = 2000, -- Sector 13: PokemonStorage chunk 8
}

Gen3Save.SECTOR_SIZES = SECTOR_SIZES

-- Substructure permutation orders based on (personality % 24).
-- Substructs: 0 = Growth, 1 = Attacks, 2 = EVs, 3 = Misc.
local SUBSTRUCT_ORDERS = {
  [0]  = { 0, 1, 2, 3 }, -- G A E M
  [1]  = { 0, 1, 3, 2 }, -- G A M E
  [2]  = { 0, 2, 1, 3 }, -- G E A M
  [3]  = { 0, 2, 3, 1 }, -- G E M A
  [4]  = { 0, 3, 1, 2 }, -- G M A E
  [5]  = { 0, 3, 2, 1 }, -- G M E A
  [6]  = { 1, 0, 2, 3 }, -- A G E M
  [7]  = { 1, 0, 3, 2 }, -- A G M E
  [8]  = { 1, 2, 0, 3 }, -- A E G M
  [9]  = { 1, 2, 3, 0 }, -- A E M G
  [10] = { 1, 3, 0, 2 }, -- A M G E
  [11] = { 1, 3, 2, 0 }, -- A M E G
  [12] = { 2, 0, 1, 3 }, -- E G A M
  [13] = { 2, 0, 3, 1 }, -- E G M A
  [14] = { 2, 1, 0, 3 }, -- E A G M
  [15] = { 2, 1, 3, 0 }, -- E A M G
  [16] = { 2, 3, 0, 1 }, -- E M G A
  [17] = { 2, 3, 1, 0 }, -- E M A G
  [18] = { 3, 0, 1, 2 }, -- M G A E
  [19] = { 3, 0, 2, 1 }, -- M G E A
  [20] = { 3, 1, 0, 2 }, -- M A G E
  [21] = { 3, 1, 2, 0 }, -- M A E G
  [22] = { 3, 2, 0, 1 }, -- M E G A
  [23] = { 3, 2, 1, 0 }, -- M E A G
}

function Gen3Save.layoutFor(gameVersion)
  if gameVersion == "firered" or gameVersion == "leafgreen" then
    return {
      version = gameVersion,
      saveSize = Gen3Save.SAVE_SIZE,
      sectorSizes = SECTOR_SIZES,
    }
  end
  return nil
end

function Gen3Save.isGen3(gameVersion)
  return Gen3Save.layoutFor(gameVersion) ~= nil
end

-- ------------------------------------------------------------------
-- Byte & Buffer Helpers
-- ------------------------------------------------------------------

local function toU32(n)
  n = tonumber(n) or 0
  if n < 0 then n = n + 4294967296 end
  return n % 4294967296
end

local function u8(b, o)
  if type(b) == "string" then return b:byte(o + 1) or 0 end
  return b[o] or 0
end

-- Copy `len` bytes from src (string or 0-indexed table) starting at srcOff
-- into dst (0-indexed table) starting at dstOff.
local function appendBytes(dst, dstOff, src, srcOff, len)
  for i = 0, len - 1 do
    dst[dstOff + i] = u8(src, srcOff + i)
  end
end

local function u16LE(b, o)
  return u8(b, o) + u8(b, o + 1) * 256
end

local function s16LE(b, o)
  local v = u16LE(b, o)
  if v >= 32768 then return v - 65536 end
  return v
end

local function u32LE(b, o)
  return u8(b, o) + u8(b, o + 1) * 256 + u8(b, o + 2) * 65536 + u8(b, o + 3) * 16777216
end

local function putU8(t, o, v)
  t[o] = (v or 0) % 256
end

local function putU16LE(t, o, v)
  v = (v or 0) % 65536
  t[o] = v % 256
  t[o + 1] = math.floor(v / 256) % 256
end

local function putS16LE(t, o, v)
  v = tonumber(v) or 0
  if v < 0 then v = v + 65536 end
  putU16LE(t, o, v)
end

local function putU32LE(t, o, v)
  v = toU32(v or 0)
  t[o] = v % 256
  t[o + 1] = math.floor(v / 256) % 256
  t[o + 2] = math.floor(v / 65536) % 256
  t[o + 3] = math.floor(v / 16777216) % 256
end

-- ------------------------------------------------------------------
-- Text Codec (GBA Character Encoding)
-- ------------------------------------------------------------------

local REVERSE_CHARMAP = nil
local function reverseCharmap()
  if REVERSE_CHARMAP then return REVERSE_CHARMAP end
  REVERSE_CHARMAP = {}
  for code, glyph in pairs(TextIR.CHARMAP or {}) do
    if type(glyph) == "string" and #glyph > 0 and not REVERSE_CHARMAP[glyph] then
      REVERSE_CHARMAP[glyph] = code
    end
  end
  -- Fallback ASCII mappings: only needed when TextIR.CHARMAP is absent.
  if not TextIR.CHARMAP or not next(TextIR.CHARMAP) then
    for b = 0, 25 do
      local upper = string.char(65 + b)
      local lower = string.char(97 + b)
      REVERSE_CHARMAP[upper] = REVERSE_CHARMAP[upper] or (0xBB + b)
      REVERSE_CHARMAP[lower] = REVERSE_CHARMAP[lower] or (0xD5 + b)
    end
    for b = 0, 9 do
      local digit = string.char(48 + b)
      REVERSE_CHARMAP[digit] = REVERSE_CHARMAP[digit] or (0xA1 + b)
    end
  end
  REVERSE_CHARMAP[" "] = 0x00
  return REVERSE_CHARMAP
end

local function decodeText(b, o, maxLen)
  local out = {}
  for i = 0, maxLen - 1 do
    local byte = u8(b, o + i)
    if byte == 0xFF then break end
    local ch = TextIR.CHARMAP and TextIR.CHARMAP[byte]
    if ch then
      out[#out + 1] = ch
    elseif byte >= 0xBB and byte <= 0xD4 then
      out[#out + 1] = string.char(65 + (byte - 0xBB))
    elseif byte >= 0xD5 and byte <= 0xEE then
      out[#out + 1] = string.char(97 + (byte - 0xD5))
    elseif byte >= 0xA1 and byte <= 0xAA then
      out[#out + 1] = string.char(48 + (byte - 0xA1))
    elseif byte == 0x00 then
      out[#out + 1] = " "
    else
      out[#out + 1] = "?"
    end
  end
  return table.concat(out)
end

local function putText(t, o, str, maxLen)
  local rev = reverseCharmap()
  str = tostring(str or "")
  local written = 0
  local i = 1
  while i <= #str and written < maxLen do
    local c = str:sub(i, i)
    local code = rev[c] or 0x00
    t[o + written] = code
    written = written + 1
    i = i + 1
  end
  if written < maxLen then
    t[o + written] = 0xFF
    written = written + 1
  end
  while written < maxLen do
    t[o + written] = 0x00
    written = written + 1
  end
end

-- ------------------------------------------------------------------
-- Checksum Calculation
-- ------------------------------------------------------------------

-- pokefirered CalculateChecksum: 32-bit addition folded into 16 bits.
function Gen3Save.calculateSectorChecksum(b, offset, size)
  local sum = 0
  local numWords = math.floor(size / 4)
  for i = 0, numWords - 1 do
    local w = u32LE(b, offset + i * 4)
    sum = (sum + w) % 4294967296
  end
  local hi = math.floor(sum / 65536)
  local lo = sum % 65536
  return (hi + lo) % 65536
end

-- Validates that the flash save contains at least one intact slot with all 14 sectors.
function Gen3Save.checksumValid(bytes)
  if type(bytes) ~= "string" or #bytes < Gen3Save.SECTOR_SIZE * Gen3Save.SECTORS_PER_SLOT then
    return false
  end
  for slot = 0, Gen3Save.NUM_SLOTS - 1 do
    local slotOffset = slot * Gen3Save.SECTORS_PER_SLOT * Gen3Save.SECTOR_SIZE
    if #bytes >= slotOffset + Gen3Save.SECTORS_PER_SLOT * Gen3Save.SECTOR_SIZE then
      local slotValid = true
      local foundSectors = {}
      for sec = 0, Gen3Save.SECTORS_PER_SLOT - 1 do
        local secOffset = slotOffset + sec * Gen3Save.SECTOR_SIZE
        local footerOffset = secOffset + 4096 - 12
        local secId = u16LE(bytes, footerOffset)
        local storedSum = u16LE(bytes, footerOffset + 2)
        local sig = u32LE(bytes, footerOffset + 4)
        if sig ~= Gen3Save.SECTOR_SIGNATURE or secId > 13 or foundSectors[secId] then
          slotValid = false
          break
        end
        local expectedSize = SECTOR_SIZES[secId]
        if not expectedSize then
          slotValid = false
          break
        end
        local calcSum = Gen3Save.calculateSectorChecksum(bytes, secOffset, expectedSize)
        if calcSum ~= storedSum then
          slotValid = false
          break
        end
        foundSectors[secId] = true
      end
      if slotValid then
        local count = 0
        for i = 0, 13 do if foundSectors[i] then count = count + 1 end end
        if count == 14 then return true end
      end
    end
  end
  return false
end

-- ------------------------------------------------------------------
-- Substructure & Pokémon Cryptography
-- ------------------------------------------------------------------

local function xorSubstructs(words, key)
  local out = {}
  for i = 0, 11 do
    out[i] = toU32(bit.bxor(words[i] or 0, key))
  end
  return out
end

local function wordsToBytes(words)
  local b = {}
  for i = 0, 11 do
    local w = toU32(words[i] or 0)
    b[i * 4]     = w % 256
    b[i * 4 + 1] = math.floor(w / 256) % 256
    b[i * 4 + 2] = math.floor(w / 65536) % 256
    b[i * 4 + 3] = math.floor(w / 16777216) % 256
  end
  return b
end

local function bytesToWords(b, o)
  local words = {}
  for i = 0, 11 do
    words[i] = u32LE(b, (o or 0) + i * 4)
  end
  return words
end

local function calculateSubstructChecksum(substructBytes)
  local sum = 0
  for i = 0, 23 do
    local w = u16LE(substructBytes, i * 2)
    sum = (sum + w) % 65536
  end
  return sum
end

local function decodePokemon(bytes, o, isParty)
  local personality = u32LE(bytes, o)
  local otId = u32LE(bytes, o + 4)
  if personality == 0 and otId == 0 then return nil end

  local nickname = decodeText(bytes, o + 8, 10)
  local otName = decodeText(bytes, o + 20, 7)

  local encryptedWords = bytesToWords(bytes, o + 32)
  local key = toU32(bit.bxor(personality, otId))
  local decryptedWords = xorSubstructs(encryptedWords, key)
  local decryptedBytes = wordsToBytes(decryptedWords)

  local storedChecksum = u16LE(bytes, o + 28)
  local calcChecksum = calculateSubstructChecksum(decryptedBytes)
  if storedChecksum ~= calcChecksum then
    return nil -- Corrupted or uninitialized Pokémon
  end

  local order = SUBSTRUCT_ORDERS[personality % 24]

  -- Split the 48 decrypted bytes into four 12-byte substructs
  local substructOffsets = {}
  for pos, substructId in ipairs(order) do
    substructOffsets[substructId] = (pos - 1) * 12
  end

  -- Substruct 0: Growth
  local gOff = substructOffsets[0]
  local species = u16LE(decryptedBytes, gOff)
  if species == 0 then return nil end
  local heldItem = u16LE(decryptedBytes, gOff + 2)
  local exp = u32LE(decryptedBytes, gOff + 4)
  local friendship = u8(decryptedBytes, gOff + 9)

  -- Substruct 1: Attacks
  local aOff = substructOffsets[1]
  local moves = {}
  local pp = {}
  for i = 0, 3 do
    local mv = u16LE(decryptedBytes, aOff + i * 2)
    if mv > 0 then
      moves[#moves + 1] = mv
      pp[#pp + 1] = u8(decryptedBytes, aOff + 8 + i)
    end
  end

  -- Substruct 2: EVs & Condition
  local eOff = substructOffsets[2]
  local evs = {
    hp  = u8(decryptedBytes, eOff),
    atk = u8(decryptedBytes, eOff + 1),
    def = u8(decryptedBytes, eOff + 2),
    spe = u8(decryptedBytes, eOff + 3),
    spa = u8(decryptedBytes, eOff + 4),
    spd = u8(decryptedBytes, eOff + 5),
  }

  -- Substruct 3: Misc
  local mOff = substructOffsets[3]
  local pokerus = u8(decryptedBytes, mOff)
  local metLocation = u8(decryptedBytes, mOff + 1)
  local originData = u16LE(decryptedBytes, mOff + 2)
  local metLevel = bit.band(originData, 0x7F)
  local pokeball = bit.band(bit.rshift(originData, 11), 0x0F)

  local ivsWord = u32LE(decryptedBytes, mOff + 4)
  local ivs = {
    hp  = bit.band(ivsWord, 0x1F),
    atk = bit.band(bit.rshift(ivsWord, 5), 0x1F),
    def = bit.band(bit.rshift(ivsWord, 10), 0x1F),
    spe = bit.band(bit.rshift(ivsWord, 15), 0x1F),
    spa = bit.band(bit.rshift(ivsWord, 20), 0x1F),
    spd = bit.band(bit.rshift(ivsWord, 25), 0x1F),
  }
  local abilityNum = bit.band(bit.rshift(ivsWord, 31), 0x01)

  local mon = {
    species = species,
    speciesId = species,
    heldItem = heldItem > 0 and heldItem or nil,
    exp = exp,
    friendship = friendship,
    happiness = friendship,
    personality = personality,
    otId = bit.band(otId, 0xFFFF),
    otSecretId = bit.rshift(otId, 16),
    otName = otName,
    nickname = nickname,
    moves = moves,
    pp = pp,
    evs = evs,
    ivs = ivs,
    ability = abilityNum,
    metLocation = metLocation,
    metLevel = metLevel,
    pokeball = pokeball > 0 and pokeball or 4,
    pokerus = pokerus,
  }

  if isParty then
    mon.status = u32LE(bytes, o + 80)
    mon.level = u8(bytes, o + 84)
    mon.hp = u16LE(bytes, o + 86)
    mon.maxHp = u16LE(bytes, o + 88)
    mon.attack = u16LE(bytes, o + 90)
    mon.atk = mon.attack
    mon.defense = u16LE(bytes, o + 92)
    mon.def = mon.defense
    mon.speed = u16LE(bytes, o + 94)
    mon.spe = mon.speed
    mon.spAtk = u16LE(bytes, o + 96)
    mon.spa = mon.spAtk
    mon.spDef = u16LE(bytes, o + 98)
    mon.spd = mon.spDef
  end

  return mon
end

local function encodePokemon(t, o, mon, isParty)
  if type(mon) ~= "table" or not (mon.species or mon.speciesId) then
    for i = 0, (isParty and 100 or 80) - 1 do t[o + i] = 0 end
    return
  end

  local personality = toU32(mon.personality or 0x12345678)
  local trainerId = tonumber(mon.otId) or 0
  local secretId = tonumber(mon.otSecretId) or 0
  local fullOtId = toU32(bit.bor(bit.band(trainerId, 0xFFFF), bit.lshift(bit.band(secretId, 0xFFFF), 16)))

  -- Substruct 0: Growth
  local sub0 = {}
  for i = 0, 11 do sub0[i] = 0 end
  putU16LE(sub0, 0, tonumber(mon.species) or tonumber(mon.speciesId) or 1)
  putU16LE(sub0, 2, tonumber(mon.heldItem or mon.item) or 0)
  putU32LE(sub0, 4, tonumber(mon.exp or mon.experience) or 0)
  putU8(sub0, 9, tonumber(mon.friendship or mon.happiness) or 70)

  -- Substruct 1: Attacks
  local sub1 = {}
  for i = 0, 11 do sub1[i] = 0 end
  local moves = mon.moves or {}
  local pps = mon.pp or {}
  for i = 1, 4 do
    local mv = moves[i]
    local mid = type(mv) == "table" and (mv.id or mv.move) or mv
    putU16LE(sub1, (i - 1) * 2, tonumber(mid) or 0)
    putU8(sub1, 8 + (i - 1), tonumber(pps[i]) or 0)
  end

  -- Substruct 2: EVs & Condition
  local sub2 = {}
  for i = 0, 11 do sub2[i] = 0 end
  local evs = mon.evs or {}
  putU8(sub2, 0, evs.hp or 0)
  putU8(sub2, 1, evs.atk or evs.attack or 0)
  putU8(sub2, 2, evs.def or evs.defense or 0)
  putU8(sub2, 3, evs.spe or evs.speed or 0)
  putU8(sub2, 4, evs.spa or evs.spAtk or evs.specialAttack or 0)
  putU8(sub2, 5, evs.spd or evs.spDef or evs.specialDefense or 0)

  -- Substruct 3: Misc
  local sub3 = {}
  for i = 0, 11 do sub3[i] = 0 end
  putU8(sub3, 0, tonumber(mon.pokerus) or 0)
  putU8(sub3, 1, tonumber(mon.metLocation) or 88) -- Pallet Town default
  local pokeball = tonumber(mon.pokeball) or 4
  local metLvl = tonumber(mon.metLevel) or tonumber(mon.level) or 5
  local originWord = bit.bor(bit.band(metLvl, 0x7F), bit.lshift(4, 7), bit.lshift(bit.band(pokeball, 0x0F), 11))
  putU16LE(sub3, 2, originWord)

  local ivs = mon.ivs or {}
  local hpIV  = bit.band(ivs.hp or 15, 0x1F)
  local atkIV = bit.band(ivs.atk or ivs.attack or 15, 0x1F)
  local defIV = bit.band(ivs.def or ivs.defense or 15, 0x1F)
  local speIV = bit.band(ivs.spe or ivs.speed or 15, 0x1F)
  local spaIV = bit.band(ivs.spa or ivs.spAtk or ivs.specialAttack or 15, 0x1F)
  local spdIV = bit.band(ivs.spd or ivs.spDef or ivs.specialDefense or 15, 0x1F)
  local abilityBit = bit.band(tonumber(mon.ability or mon.abilityId) or 0, 0x01)
  local ivWord = hpIV + bit.lshift(atkIV, 5) + bit.lshift(defIV, 10) + bit.lshift(speIV, 15)
                 + bit.lshift(spaIV, 20) + bit.lshift(spdIV, 25) + bit.lshift(abilityBit, 31)
  putU32LE(sub3, 4, ivWord)

  local unencrypted = {}
  for i = 0, 47 do unencrypted[i] = 0 end
  for i = 0, 11 do
    unencrypted[i]      = sub0[i]
    unencrypted[12 + i] = sub1[i]
    unencrypted[24 + i] = sub2[i]
    unencrypted[36 + i] = sub3[i]
  end

  local checksum = calculateSubstructChecksum(unencrypted)

  -- Order substructs based on personality % 24
  local order = SUBSTRUCT_ORDERS[personality % 24]
  local subs = { [0] = sub0, [1] = sub1, [2] = sub2, [3] = sub3 }

  local ordered = {}
  for pos, subId in ipairs(order) do
    local sourceSub = subs[subId]
    for i = 0, 11 do
      ordered[(pos - 1) * 12 + i] = sourceSub[i]
    end
  end

  local orderedWords = bytesToWords(ordered)
  local key = toU32(bit.bxor(personality, fullOtId))
  local encryptedWords = xorSubstructs(orderedWords, key)
  local encryptedBytes = wordsToBytes(encryptedWords)

  -- Write BoxPokemon header (32 bytes)
  putU32LE(t, o, personality)
  putU32LE(t, o + 4, fullOtId)
  local nick = mon.nickname or mon.name or "MON"
  putText(t, o + 8, nick, 10)
  putU8(t, o + 18, 0x02) -- English
  putU8(t, o + 19, 0x00)
  local ot = mon.otName or mon.ot or "RED"
  putText(t, o + 20, ot, 7)
  putU8(t, o + 27, 0x00)
  putU16LE(t, o + 28, checksum)
  putU16LE(t, o + 30, 0x00)

  -- Write encrypted substructs (48 bytes)
  for i = 0, 47 do
    t[o + 32 + i] = encryptedBytes[i]
  end

  -- If Party Pokémon, write 20 trailing bytes
  if isParty then
    putU32LE(t, o + 80, tonumber(mon.status) or 0)
    putU8(t, o + 84, tonumber(mon.level) or 5)
    putU8(t, o + 85, 0xFF) -- mail
    putU16LE(t, o + 86, tonumber(mon.hp) or 20)
    putU16LE(t, o + 88, tonumber(mon.maxHp or mon.hp) or 20)
    putU16LE(t, o + 90, tonumber(mon.attack or mon.atk) or 10)
    putU16LE(t, o + 92, tonumber(mon.defense or mon.def) or 10)
    putU16LE(t, o + 94, tonumber(mon.speed or mon.spe) or 10)
    putU16LE(t, o + 96, tonumber(mon.spAtk or mon.spa) or 10)
    putU16LE(t, o + 98, tonumber(mon.spDef or mon.spd) or 10)
  end
end

-- ------------------------------------------------------------------
-- Decode: Flash Save -> Engine Save Table
-- ------------------------------------------------------------------

function Gen3Save.decode(bytes, gameVersion, data)
  if type(bytes) ~= "string" or #bytes < Gen3Save.SECTOR_SIZE * Gen3Save.SECTORS_PER_SLOT then
    return nil, "save file is truncated (must be at least 57,344 bytes)"
  end

  local validSlots = {}
  for slot = 0, Gen3Save.NUM_SLOTS - 1 do
    local slotOffset = slot * Gen3Save.SECTORS_PER_SLOT * Gen3Save.SECTOR_SIZE
    if #bytes >= slotOffset + Gen3Save.SECTORS_PER_SLOT * Gen3Save.SECTOR_SIZE then
      local sectors = {}
      local counter = nil
      local slotOk = true
      for sec = 0, Gen3Save.SECTORS_PER_SLOT - 1 do
        local secOffset = slotOffset + sec * Gen3Save.SECTOR_SIZE
        local footerOffset = secOffset + 4096 - 12
        local secId = u16LE(bytes, footerOffset)
        local storedSum = u16LE(bytes, footerOffset + 2)
        local sig = u32LE(bytes, footerOffset + 4)
        local c = u32LE(bytes, footerOffset + 8)

        if sig ~= Gen3Save.SECTOR_SIGNATURE or secId > 13 or sectors[secId] then
          slotOk = false
          break
        end
        local expectedSize = SECTOR_SIZES[secId]
        if not expectedSize then
          slotOk = false
          break
        end
        local calcSum = Gen3Save.calculateSectorChecksum(bytes, secOffset, expectedSize)
        if calcSum ~= storedSum then
          slotOk = false
          break
        end
        sectors[secId] = secOffset
        counter = counter or c
      end
      if slotOk then
        local count = 0
        for i = 0, 13 do if sectors[i] then count = count + 1 end end
        if count == 14 then
          validSlots[#validSlots + 1] = { slot = slot, counter = counter or 0, sectors = sectors }
        end
      end
    end
  end

  if #validSlots == 0 then
    return nil, "no valid save slot found (all sector signatures or checksums invalid)"
  end

  table.sort(validSlots, function(a, b) return a.counter > b.counter end)
  local active = validSlots[1].sectors

  -- Assemble continuous buffers
  -- SaveBlock2: Sector 0 (3884 bytes)
  local sb2Offset = active[0]

  -- SaveBlock1: Sector 1 (3968), Sector 2 (3968), Sector 3 (3968), Sector 4 (3848)
  local sb1 = {}
  local sb1Len = 0
  for _, chunk in ipairs({ {active[1], 3968}, {active[2], 3968}, {active[3], 3968}, {active[4], 3848} }) do
    appendBytes(sb1, sb1Len, bytes, chunk[1], chunk[2])
    sb1Len = sb1Len + chunk[2]
  end

  -- PokemonStorage: Sectors 5..12 (3968*8), Sector 13 (2000)
  local pks = {}
  local pksLen = 0
  for sec = 5, 12 do
    appendBytes(pks, pksLen, bytes, active[sec], 3968)
    pksLen = pksLen + 3968
  end
  appendBytes(pks, pksLen, bytes, active[13], 2000)

  -- Parse SaveBlock2
  local playerName = decodeText(bytes, sb2Offset, 7)
  local playerGender = u8(bytes, sb2Offset + 8)
  local trainerId = u16LE(bytes, sb2Offset + 10)
  local secretId = u16LE(bytes, sb2Offset + 12)
  local playHours = u16LE(bytes, sb2Offset + 14)
  local playMins = u8(bytes, sb2Offset + 16)
  local playSecs = u8(bytes, sb2Offset + 17)
  local playVBlanks = u8(bytes, sb2Offset + 18)

  local optionsButtonMode = u8(bytes, sb2Offset + 19)
  local optionsByte2 = u8(bytes, sb2Offset + 20)
  local optionsByte3 = u8(bytes, sb2Offset + 21)

  local textSpeed = bit.band(optionsByte2, 0x07)
  local windowFrame = bit.rshift(optionsByte2, 3)
  local soundMode = bit.band(optionsByte3, 0x01)
  local battleStyle = bit.band(bit.rshift(optionsByte3, 1), 0x01)
  local battleAnimOff = bit.band(bit.rshift(optionsByte3, 2), 0x01)

  -- Pokédex flags
  local nationalPokedex = (u8(bytes, sb2Offset + 26) == 0xB9)
  local ownedMap = {}
  for i = 0, Gen3Save.NUM_SPECIES - 1 do
    local byteVal = u8(bytes, sb2Offset + 27 + math.floor(i / 8))
    if bit.band(bit.rshift(byteVal, i % 8), 0x01) == 1 then
      ownedMap[i + 1] = true
    end
  end
  local seenMap = {}
  for i = 0, Gen3Save.NUM_SPECIES - 1 do
    local byteVal = u8(bytes, sb2Offset + 76 + math.floor(i / 8))
    if bit.band(bit.rshift(byteVal, i % 8), 0x01) == 1 then
      seenMap[i + 1] = true
    end
  end

  local encryptionKey = u32LE(bytes, sb2Offset + 0xF20)
  local key16 = bit.band(encryptionKey, 0xFFFF)

  -- Parse SaveBlock1
  local posX = s16LE(sb1, 0)
  local posY = s16LE(sb1, 2)
  local mapGroup = u8(sb1, 4)
  local mapNum = u8(sb1, 5)
  local mapId = MapCatalog.mapIdFor(mapGroup, mapNum) or "FR_PALLET_TOWN"

  local healGroup = u8(sb1, 28)
  local healNum = u8(sb1, 29)
  local healMap = MapCatalog.mapIdFor(healGroup, healNum) or "FR_PLAYERS_HOUSE_1F"
  local healX = s16LE(sb1, 32)
  local healY = s16LE(sb1, 34)

  local flashLevel = u8(sb1, 48)
  local partyCount = math.min(u8(sb1, 52), 6)
  local party = {}
  for i = 0, partyCount - 1 do
    local mon = decodePokemon(sb1, 56 + i * 100, true)
    if mon then party[#party + 1] = mon end
  end

  local money = toU32(bit.bxor(u32LE(sb1, 0x0290), encryptionKey))
  local coins = toU32(bit.bxor(u16LE(sb1, 0x0294), key16)) % 65536
  local registeredItem = u16LE(sb1, 0x0296)

  -- Items
  local function readPocket(startOffset, maxSlots, xorQty)
    local slots = {}
    for i = 0, maxSlots - 1 do
      local ioff = startOffset + i * 4
      local itemId = u16LE(sb1, ioff)
      local qty = u16LE(sb1, ioff + 2)
      if xorQty then qty = toU32(bit.bxor(qty, key16)) % 65536 end
      if itemId > 0 and qty > 0 then
        slots[#slots + 1] = { id = itemId, qty = qty }
      end
    end
    return slots
  end

  local pcItems = readPocket(0x0298, 30, false)
  local bagPockets = {
    ITEMS       = readPocket(0x0310, 42, true),
    KEY_ITEMS   = readPocket(0x03B8, 30, false),
    POKE_BALLS  = readPocket(0x0430, 13, true),
    TM_CASE     = readPocket(0x0464, 58, true),
    BERRY_POUCH = readPocket(0x054C, 43, true),
  }

  -- Flags and vars
  local flags = {}
  for i = 0, 299 do
    local b = u8(sb1, 0x0EE0 + i)
    for bitIdx = 0, 7 do
      if bit.band(bit.rshift(b, bitIdx), 0x01) == 1 then
        local flagId = i * 8 + bitIdx
        flags[tostring(flagId)] = true
      end
    end
  end

  local vars = {}
  for i = 0, 255 do
    local v = u16LE(sb1, 0x1000 + i * 2)
    if v > 0 then vars[i] = v end
  end

  local rivalName = decodeText(sb1, 0x3A4C, 7)

  -- Parse PokemonStorage
  local currentBox = u32LE(pks, 0) + 1
  local boxes = {}
  for b = 1, Gen3Save.TOTAL_BOXES do
    local mons = {}
    local boxBase = 4 + (b - 1) * Gen3Save.BOX_CAPACITY * Gen3Save.BOX_MON_STRUCT
    for m = 1, Gen3Save.BOX_CAPACITY do
      local mon = decodePokemon(pks, boxBase + (m - 1) * Gen3Save.BOX_MON_STRUCT, false)
      if mon then mons[m] = mon end
    end
    local nameBase = 0x8344 + (b - 1) * 9
    local bName = decodeText(pks, nameBase, 8)
    local wallpaper = u8(pks, 0x83C2 + (b - 1)) + 1
    boxes[b] = {
      name = (bName ~= "" and bName or ("BOX " .. b)),
      wallpaper = wallpaper,
      mons = mons,
    }
  end

  return {
    schemaVersion = Schema.VERSION,
    engine = "game3",
    version = gameVersion or "firered",
    generation = 3,
    name = playerName,
    playerName = playerName,
    gender = playerGender,
    trainerId = trainerId,
    secretId = secretId,
    trainer = {
      name = playerName,
      gender = playerGender,
      id = trainerId,
      secret = secretId,
    },
    player = {
      name = playerName,
      map = mapId,
      x = posX,
      y = posY,
    },
    encryptionKey = encryptionKey,
    playTime = {
      hours = playHours,
      minutes = playMins,
      seconds = playSecs,
      vblanks = playVBlanks,
    },
    options = {
      buttonMode = optionsButtonMode,
      textSpeed = textSpeed,
      windowFrame = windowFrame,
      sound = soundMode == 1 and "stereo" or "mono",
      battleStyle = battleStyle == 1 and "set" or "shift",
      battleScene = battleAnimOff == 0,
    },
    dex = {
      seen = seenMap,
      owned = ownedMap,
      national = nationalPokedex,
    },
    map = mapId,
    x = posX,
    y = posY,
    facing = "down",
    healMap = healMap,
    healX = healX,
    healY = healY,
    flashLevel = flashLevel,
    party = party,
    money = money,
    coins = coins,
    registeredItem = registeredItem > 0 and registeredItem or nil,
    bag = {
      pockets = bagPockets,
      stacks = {},
    },
    storage = {
      currentBox = currentBox,
      boxes = boxes,
      items = pcItems,
    },
    flags = flags,
    vars = vars,
    rivalName = rivalName,
  }
end

function Gen3Save.mergeDefaults(decoded, gameVersion)
  local session = Schema.fromSaveTable(decoded)
  if not session.rng then
    local encryptionKey = tonumber(decoded.encryptionKey) or 0
    session.rng = { value = encryptionKey, value2 = 0, wild = 0 }
  end
  local save = Schema.toSaveTable(session)
  save.engine = "game3"
  save.generation = 3
  save.version = gameVersion or "firered"
  save.trainer = {
    name = save.name,
    gender = save.gender,
    id = save.trainerId,
    secret = save.secretId,
  }
  save.player = {
    name = save.name,
    map = save.map,
    x = save.x,
    y = save.y,
  }
  save.pokedex = save.dex
  return save
end

-- ------------------------------------------------------------------
-- Encode: Engine Save Table -> 128 KiB Flash Save
-- ------------------------------------------------------------------

function Gen3Save.encode(save, gameVersion, template, data)
  if type(save) ~= "table" then
    return nil, "expected a save table"
  end

  local saveCounter = 1
  local t = {}
  local hasTemplate = (type(template) == "string" and #template >= Gen3Save.SAVE_SIZE)

  if hasTemplate then
    for i = 0, Gen3Save.SAVE_SIZE - 1 do t[i] = template:byte(i + 1) end
    local existingCounter = u32LE(template, 4096 - 4)
    if existingCounter > 0 then saveCounter = existingCounter + 1 end
  else
    for i = 0, Gen3Save.SAVE_SIZE - 1 do t[i] = 0 end
  end

  local encryptionKey = tonumber(save.encryptionKey)
  if not encryptionKey or encryptionKey == 0 then
    local tid = tonumber(save.trainerId) or tonumber(save.trainer and save.trainer.id) or 1234
    local sid = tonumber(save.secretId) or tonumber(save.trainer and save.trainer.secret) or 5678
    encryptionKey = toU32(tid * 65536 + sid)
    if encryptionKey == 0 then encryptionKey = 0x54321 end
  end
  local key16 = bit.band(encryptionKey, 0xFFFF)

  -- Build SaveBlock2 (3884 bytes)
  local sb2 = {}
  for i = 0, 3883 do sb2[i] = 0 end
  local pName = save.name or save.playerName or (save.trainer and save.trainer.name) or (save.player and save.player.name) or "RED"
  putText(sb2, 0, pName, 8)
  local gender = (save.gender == 1 or save.gender == "female" or (save.trainer and (save.trainer.gender == 1 or save.trainer.gender == "female"))) and 1 or 0
  putU8(sb2, 8, gender)
  local tid = tonumber(save.trainerId) or tonumber(save.trainer and save.trainer.id) or 0
  local sid = tonumber(save.secretId) or tonumber(save.trainer and save.trainer.secret) or 0
  putU16LE(sb2, 10, bit.band(tid, 0xFFFF))
  putU16LE(sb2, 12, bit.band(sid, 0xFFFF))

  local pt = save.playTime or save.playtime or {}
  putU16LE(sb2, 14, tonumber(pt.hours) or 0)
  putU8(sb2, 16, tonumber(pt.minutes) or 0)
  putU8(sb2, 17, tonumber(pt.seconds) or 0)
  putU8(sb2, 18, tonumber(pt.vblanks) or 0)

  local opt = save.options or {}
  putU8(sb2, 19, tonumber(opt.buttonMode) or 0)
  local speedBits = tonumber(opt.textSpeed) or 1
  local frameBits = tonumber(opt.windowFrame) or 0
  putU8(sb2, 20, bit.bor(bit.band(speedBits, 0x07), bit.lshift(bit.band(frameBits, 0x1F), 3)))
  local soundBit = (opt.sound == "stereo") and 1 or 0
  local styleBit = (opt.battleStyle == "set") and 1 or 0
  local sceneOffBit = (opt.battleScene == false) and 1 or 0
  putU8(sb2, 21, bit.bor(soundBit, bit.lshift(styleBit, 1), bit.lshift(sceneOffBit, 2)))

  local dex = save.dex or save.pokedex or {}
  if dex.national then putU8(sb2, 26, 0xB9) end
  local owned = dex.owned or dex.caught or {}
  for sp = 1, Gen3Save.NUM_SPECIES do
    if owned[sp] then
      local byteIdx = 27 + math.floor((sp - 1) / 8)
      sb2[byteIdx] = bit.bor(sb2[byteIdx] or 0, bit.lshift(1, (sp - 1) % 8))
    end
  end
  local seen = dex.seen or {}
  for sp = 1, Gen3Save.NUM_SPECIES do
    if seen[sp] then
      local byteIdx = 76 + math.floor((sp - 1) / 8)
      sb2[byteIdx] = bit.bor(sb2[byteIdx] or 0, bit.lshift(1, (sp - 1) % 8))
    end
  end
  putU32LE(sb2, 0xF20, encryptionKey)

  -- Build SaveBlock1 (15752 bytes)
  local sb1 = {}
  for i = 0, 15751 do sb1[i] = 0 end

  local posX = tonumber(save.x) or tonumber(save.player and save.player.x) or 0
  local posY = tonumber(save.y) or tonumber(save.player and save.player.y) or 0
  putS16LE(sb1, 0, posX)
  putS16LE(sb1, 2, posY)

  local mapIdStr = save.map or (save.player and save.player.map)
  local slotKey = MapCatalog.slotKeyFor(mapIdStr)
  local mapGroup, mapNum = 3, 0 -- Pallet Town default
  if slotKey then
    local g, n = slotKey:match("^(%d+)_(%d+)$")
    if g and n then mapGroup, mapNum = tonumber(g), tonumber(n) end
  end
  putU8(sb1, 4, mapGroup)
  putU8(sb1, 5, mapNum)
  putU8(sb1, 6, 0) -- warpId
  putS16LE(sb1, 8, posX)
  putS16LE(sb1, 10, posY)

  -- continueGameWarp
  putU8(sb1, 12, mapGroup); putU8(sb1, 13, mapNum); putU8(sb1, 14, 0)
  putS16LE(sb1, 16, posX); putS16LE(sb1, 18, posY)

  -- lastHealLocation
  local healMapStr = save.healMap or (save.lastHeal and save.lastHeal.map)
  local healKey = MapCatalog.slotKeyFor(healMapStr)
  local hGroup, hNum = 4, 0 -- Player's House 1F default
  if healKey then
    local g, n = healKey:match("^(%d+)_(%d+)$")
    if g and n then hGroup, hNum = tonumber(g), tonumber(n) end
  end
  local healX = tonumber(save.healX) or tonumber(save.lastHeal and save.lastHeal.x) or 8
  local healY = tonumber(save.healY) or tonumber(save.lastHeal and save.lastHeal.y) or 5
  putU8(sb1, 28, hGroup); putU8(sb1, 29, hNum); putU8(sb1, 30, 0)
  putS16LE(sb1, 32, healX); putS16LE(sb1, 34, healY)

  putU8(sb1, 48, tonumber(save.flashLevel) or 0)

  local party = save.party or {}
  local pCount = math.min(#party, 6)
  putU8(sb1, 52, pCount)
  for i = 1, pCount do
    encodePokemon(sb1, 56 + (i - 1) * 100, party[i], true)
  end

  putU32LE(sb1, 0x0290, toU32(bit.bxor(tonumber(save.money) or 0, encryptionKey)))
  putU16LE(sb1, 0x0294, toU32(bit.bxor(tonumber(save.coins) or 0, key16)) % 65536)
  putU16LE(sb1, 0x0296, tonumber(save.registeredItem) or 0)

  -- PC Items
  local pcList = (save.storage and save.storage.items) or {}
  for i = 1, math.min(#pcList, 30) do
    local it = pcList[i]
    local ioff = 0x0298 + (i - 1) * 4
    putU16LE(sb1, ioff, ItemsData.toNumericId(it.id) or tonumber(it.id) or 0)
    putU16LE(sb1, ioff + 2, tonumber(it.qty) or 1)
  end

  -- Bag Pockets
  local bag = save.bag or save.inventory or {}
  local pockets = bag.pockets or {}
  local function writePocket(startOffset, maxSlots, list, xorQty)
    for i = 1, math.min(#(list or {}), maxSlots) do
      local it = list[i]
      local ioff = startOffset + (i - 1) * 4
      local nid = ItemsData.toNumericId(it.id) or tonumber(it.id) or 0
      local qty = tonumber(it.qty) or 1
      if xorQty then qty = toU32(bit.bxor(qty, key16)) % 65536 end
      putU16LE(sb1, ioff, nid)
      putU16LE(sb1, ioff + 2, qty)
    end
  end

  writePocket(0x0310, 42, pockets.ITEMS, true)
  writePocket(0x03B8, 30, pockets.KEY_ITEMS, false)
  writePocket(0x0430, 13, pockets.POKE_BALLS, true)
  writePocket(0x0464, 58, pockets.TM_CASE, true)
  writePocket(0x054C, 43, pockets.BERRY_POUCH, true)

  -- Pokedex seen copy 1 & 2
  for sp = 1, Gen3Save.NUM_SPECIES do
    if seen[sp] then
      local bOff = math.floor((sp - 1) / 8)
      local mask = bit.lshift(1, (sp - 1) % 8)
      sb1[0x05F8 + bOff] = bit.bor(sb1[0x05F8 + bOff] or 0, mask)
      sb1[0x3A18 + bOff] = bit.bor(sb1[0x3A18 + bOff] or 0, mask)
    end
  end

  -- Flags
  for id, on in pairs(save.flags or {}) do
    if on then
      local nid = tonumber(id)
      if nid and nid >= 0 and nid < 2400 then
        local bIdx = 0x0EE0 + math.floor(nid / 8)
        sb1[bIdx] = bit.bor(sb1[bIdx] or 0, bit.lshift(1, nid % 8))
      end
    end
  end

  -- Vars
  for vid, val in pairs(save.vars or {}) do
    local nvid = tonumber(vid)
    if nvid and nvid >= 0 and nvid < 256 then
      putU16LE(sb1, 0x1000 + nvid * 2, tonumber(val) or 0)
    end
  end

  putText(sb1, 0x3A4C, save.rivalName or "BLUE", 8)

  -- Build PokemonStorage (33744 bytes)
  local pks = {}
  for i = 0, 33743 do pks[i] = 0 end
  local st = save.storage or {}
  local curBox = math.max(0, math.min((tonumber(st.currentBox) or 1) - 1, 13))
  putU32LE(pks, 0, curBox)

  local boxes = st.boxes or {}
  for b = 1, Gen3Save.TOTAL_BOXES do
    local box = boxes[b] or {}
    local boxMons = box.mons or {}
    local bBase = 4 + (b - 1) * Gen3Save.BOX_CAPACITY * Gen3Save.BOX_MON_STRUCT
    for m = 1, Gen3Save.BOX_CAPACITY do
      encodePokemon(pks, bBase + (m - 1) * Gen3Save.BOX_MON_STRUCT, boxMons[m], false)
    end
    putText(pks, 0x8344 + (b - 1) * 9, box.name or ("BOX " .. b), 9)
    putU8(pks, 0x83C2 + (b - 1), math.max(0, math.min((tonumber(box.wallpaper) or b) - 1, 15)))
  end

  -- Slice into 14 sectors
  local sectorData = {}
  sectorData[0] = sb2

  local function sliceTable(src, startByte, len)
    local out = {}
    appendBytes(out, 0, src, startByte, len)
    return out
  end
  sectorData[1] = sliceTable(sb1, 0, 3968)
  sectorData[2] = sliceTable(sb1, 3968, 3968)
  sectorData[3] = sliceTable(sb1, 7936, 3968)
  sectorData[4] = sliceTable(sb1, 11904, 3848)

  for sec = 5, 12 do
    sectorData[sec] = sliceTable(pks, (sec - 5) * 3968, 3968)
  end
  sectorData[13] = sliceTable(pks, 8 * 3968, 2000)

  -- Write sectors to flash image buffer
  local function writeSlot(slotIdx, counter)
    local slotOffset = slotIdx * Gen3Save.SECTORS_PER_SLOT * Gen3Save.SECTOR_SIZE
    for secId = 0, 13 do
      local secOffset = slotOffset + secId * Gen3Save.SECTOR_SIZE
      local dataSize = SECTOR_SIZES[secId]
      local sData = sectorData[secId]

      -- Copy data
      for i = 0, dataSize - 1 do
        t[secOffset + i] = sData[i] or 0
      end
      -- Zero padding up to footer
      for i = dataSize, 4096 - 13 do
        t[secOffset + i] = 0
      end

      -- Footer: ID, Checksum, Signature, Save Counter
      local footer = secOffset + 4096 - 12
      putU16LE(t, footer, secId)
      local chk = Gen3Save.calculateSectorChecksum(t, secOffset, dataSize)
      putU16LE(t, footer + 2, chk)
      putU32LE(t, footer + 4, Gen3Save.SECTOR_SIGNATURE)
      putU32LE(t, footer + 8, counter)
    end
  end

  -- Write Slot 0 (primary) and Slot 1 (backup)
  writeSlot(0, saveCounter)
  writeSlot(1, math.max(0, saveCounter - 1))

  local out = {}
  for i = 0, Gen3Save.SAVE_SIZE - 1 do
    out[i + 1] = string.char(t[i] or 0)
  end
  return table.concat(out)
end

return Gen3Save
