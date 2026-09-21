-- Tests for Gen3 (FireRed / LeafGreen) save encoding, decoding, checksums,
-- and integration with SaveConvert and SaveFileIO.

package.path = "./?.lua;./?/init.lua;" .. package.path

local S = require("tests.harness").suite("gen3 save export")
local check, eq = S.check, S.eq

love = love or require("tests.love_stub")

local Gen3Save = require("src.save_convert.Gen3Save")
local SaveConvert = require("src.save_convert.SaveConvert")
local SaveFileIO = require("src.import.SaveFileIO")
local SaveData = require("src.core.SaveData")
local GameVersion = require("src.core.GameVersion")
local GenSave = require("src.save_convert.GenSave")

-- ---------------------------------------------------------------------------
-- 1. Metadata and format checks
-- ---------------------------------------------------------------------------
eq(SaveConvert.isGen3Cart("firered"), true, "firered is recognized as gen3 cart")
eq(SaveConvert.isGen3Cart("leafgreen"), true, "leafgreen is recognized as gen3 cart")
eq(SaveConvert.isGen3Cart("red"), false, "red is not gen3 cart")
eq(SaveConvert.isGen3Cart("gold"), false, "gold is not gen3 cart")

eq(SaveConvert.exportSupported("firered"), true, "export is supported for firered")
eq(SaveConvert.importSupported("firered"), true, "import is supported for firered")

-- ---------------------------------------------------------------------------
-- 2. Encoding from scratch: synthetic FireRed save
-- ---------------------------------------------------------------------------
local sampleSave = {
  version = "firered",
  trainer = {
    name = "ASH",
    gender = 0,
    id = 12345,
    secret = 54321,
  },
  money = 9876,
  encryptionKey = 0x12345678,
  map = "FR_PALLET_TOWN",
  player = {
    x = 10,
    y = 12,
  },
  party = {
    {
      species = 1, -- Bulbasaur
      nickname = "SAUR",
      otName = "ASH",
      otId = 12345,
      personality = 0xA1B2C3D4,
      level = 5,
      exp = 135,
      hp = 20,
      maxHp = 20,
      attack = 11,
      defense = 11,
      speed = 10,
      spAttack = 13,
      spDefense = 13,
      moves = { 33, 45, 0, 0 }, -- Tackle, Growl
      pp = { 35, 40, 0, 0 },
      ivs = { hp = 15, attack = 15, defense = 15, speed = 15, spAttack = 15, spDefense = 15 },
      evs = { hp = 0, attack = 0, defense = 0, speed = 0, spAttack = 0, spDefense = 0 },
    },
  },
  pokedex = {
    seen = { [1] = true, [4] = true },
    owned = { [1] = true },
  },
}

local encoded, encErr = Gen3Save.encode(sampleSave, "firered")
check(encoded ~= nil, "Gen3Save.encode succeeded: " .. tostring(encErr))
eq(#encoded, 131072, "encoded save is exactly 128 KiB (131072 bytes)")

eq(Gen3Save.checksumValid(encoded), true, "Gen3Save.checksumValid accepts encoded save")
eq(SaveConvert.mainChecksumValid(encoded, "firered"), true, "SaveConvert.mainChecksumValid accepts encoded save")

-- ---------------------------------------------------------------------------
-- 3. Roundtrip decoding
-- ---------------------------------------------------------------------------
local decoded, decErr = Gen3Save.decode(encoded, "firered")
check(decoded ~= nil, "Gen3Save.decode succeeded: " .. tostring(decErr))

eq(decoded.trainer.name, "ASH", "player name roundtrip")
eq(decoded.trainer.id, 12345, "trainer id roundtrip")
eq(decoded.trainer.secret, 54321, "secret id roundtrip")
eq(decoded.money, 9876, "money roundtrip")
eq(decoded.trainer.gender, 0, "gender roundtrip")
eq(decoded.player.x, 10, "player X roundtrip")
eq(decoded.player.y, 12, "player Y roundtrip")
eq(#decoded.party, 1, "party size roundtrip")

local p1 = decoded.party[1]
eq(p1.species, 1, "party mon species roundtrip")
eq(p1.nickname, "SAUR", "party mon nickname roundtrip")
eq(p1.level, 5, "party mon level roundtrip")
eq(p1.hp, 20, "party mon hp roundtrip")
eq(p1.maxHp, 20, "party mon maxHp roundtrip")
eq(p1.moves[1], 33, "party mon move 1 roundtrip")
eq(p1.moves[2], 45, "party mon move 2 roundtrip")
eq(decoded.pokedex.owned[1], true, "pokedex owned entry 1 roundtrip")
eq(decoded.pokedex.seen[4], true, "pokedex seen entry 4 roundtrip")

-- ---------------------------------------------------------------------------
-- 4. SaveConvert integration (importSav & exportSav)
-- ---------------------------------------------------------------------------
local cvtEncoded, cvtErr = SaveConvert.exportSav(sampleSave, "firered")
check(cvtEncoded ~= nil, "SaveConvert.exportSav succeeded: " .. tostring(cvtErr))
eq(#cvtEncoded, 131072, "SaveConvert.exportSav produced 128 KiB")
eq(SaveConvert.mainChecksumValid(cvtEncoded, "firered"), true, "SaveConvert output validates")

local cvtImported, cvtImpErr = SaveConvert.importSav(cvtEncoded, "firered", "firered")
check(cvtImported ~= nil, "SaveConvert.importSav succeeded: " .. tostring(cvtImpErr))
eq(cvtImported.trainer.name, "ASH", "SaveConvert.importSav player name correct")
eq(cvtImported.trainer.id, 12345, "SaveConvert.importSav trainer ID correct")

-- ---------------------------------------------------------------------------
-- 5. Defensive GenSave hardening regression test
-- ---------------------------------------------------------------------------
local badSaveForGen1 = {
  inventory = {
    pockets = { items = {} }, -- table instead of number
    keyItems = { items = {} },
  },
  player = { name = "RED", map = "PALLET_TOWN", x = 0, y = 0 },
}
local redData = SaveConvert.loadData("red")
local template = string.rep("\0", GenSave.SAVE_SIZE)
local gen1Ok, gen1Res = pcall(GenSave.encode, badSaveForGen1, redData, template)
check(gen1Ok, "GenSave.encode handles tables in inventory without comparing table to number: " .. tostring(gen1Res))

-- ---------------------------------------------------------------------------
-- 6. SaveFileIO export and import on a simulated filesystem
-- ---------------------------------------------------------------------------
local mockFiles = {}
love.filesystem = {
  files = mockFiles,
  write = function(path, content) mockFiles[path] = content return true end,
  read = function(path) return mockFiles[path] end,
  remove = function(path) mockFiles[path] = nil return true end,
  createDirectory = function(_) return true end,
  getSaveDirectory = function() return "/mock/save/dir" end,
  getInfo = function(path)
    if mockFiles[path] then return { type = "file" } end
    return nil
  end,
}

SaveData.resetSlotState()
GameVersion.set("firered")

local slotId = SaveData.createSlot("firered")
check(slotId ~= nil, "firered slot registered")
SaveData.setActiveSlot("firered", slotId)
local writeSlotOk = SaveData.writeSlot("firered", slotId, sampleSave)
eq(writeSlotOk, true, "sampleSave written to firered slot")

local expOk, expPath = SaveFileIO.exportActiveSlot("firered")
check(expOk == true, "SaveFileIO.exportActiveSlot succeeded: " .. tostring(expPath))
check(type(expPath) == "string" and expPath:find("exports/firered/gen1recomp-firered-" .. tostring(slotId) .. ".sav", 1, true) ~= nil,
      "export file placed in exports/firered/: " .. tostring(expPath))

local exportedBytes = mockFiles["exports/firered/gen1recomp-firered-" .. tostring(slotId) .. ".sav"]
check(exportedBytes ~= nil, "exported file is present in mock filesystem")
eq(#exportedBytes, 131072, "exported file is 128 KiB")
eq(Gen3Save.checksumValid(exportedBytes), true, "exported file checksum is valid")

-- Now test importToSlot using the exported bytes
local impOk, newSlot = SaveFileIO.importToSlot(exportedBytes, "firered")
check(impOk == true, "SaveFileIO.importToSlot succeeded: " .. tostring(newSlot))
check(mockFiles["saves/firered/" .. tostring(newSlot) .. ".cart"] ~= nil,
      ".cart backup written for imported Gen 3 slot")

-- ---------------------------------------------------------------------------
-- 7. Game3 continue-save and import-shape verification
-- ---------------------------------------------------------------------------
local importedSlotSave = SaveData.load("firered")
check(importedSlotSave ~= nil, "SaveData.load successfully loads imported firered slot")
eq(importedSlotSave.engine, "game3", "imported save has engine = game3")
eq(importedSlotSave.version, "firered", "imported save has version = firered")
eq(importedSlotSave.generation, 3, "imported save has generation = 3")
check(type(importedSlotSave.playTime) == "table", "imported save has playTime table")
check(type(importedSlotSave.inventory) == "table", "imported save has inventory alias")

local Game3 = require("src.core.Game3")
local game3 = Game3.new()
eq(game3:_hasContinueSave(), true, "Game3:_hasContinueSave() returns true for imported save")

local Boot = require("src.ui.game3.boot")
local cInfo = Boot.continueInfoFromSave(importedSlotSave)
check(cInfo ~= nil, "Boot.continueInfoFromSave succeeded")
eq(cInfo.name, "ASH", "Continue info name matches imported save")

-- Test migration on legacy save without engine field
local legacySave = { version = "firered", map = "FR_PALLET_TOWN", name = "OLD" }
SaveData.runMigrations(legacySave)
eq(legacySave.engine, "game3", "SaveData.runMigrations sets engine = game3 on legacy Gen3 save")
eq(legacySave.generation, 3, "SaveData.runMigrations sets generation = 3 on legacy Gen3 save")

S.finish()
