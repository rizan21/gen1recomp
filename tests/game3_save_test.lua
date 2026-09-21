-- Game3 / FireRed save file tests: slot naming, cart scopes, schema,
-- SaveData migrations, CONTINUE summary, and SaveData write/read round trip.
--
-- Pure in-memory tests standing in for love.filesystem.

package.path = "./?.lua;./src/?.lua;" .. package.path

local S = require("tests.harness").suite("game3 save")
local check, eq = S.check, S.eq

love = love or require("tests.love_stub")

local GameVersion = require("src.core.GameVersion")
local SaveData = require("src.core.SaveData")
local Schema = require("src.core.game3.save_schema_firered")
local Game3 = require("src.core.Game3")
local Boot = require("src.ui.game3.boot")

local priorVersion = GameVersion.get()
GameVersion.set("firered")

-- ---------------------------------------------------------------------------
-- 1. Filenames & Save Slot Scopes
-- ---------------------------------------------------------------------------
SaveData.resetSlotState()
local slot1 = SaveData.createSlot("firered")
check(slot1 ~= nil, "created firered slot 1")
SaveData.setActiveSlot("firered", slot1)
eq(SaveData.activeSlot("firered"), slot1, "active slot is slot1")
eq(SaveData.saveFilename("firered"), "saves/firered/" .. slot1 .. ".lua",
   "saveFilename resolves to slot directory path")

-- Cart scoping: a loaded cart redirects save path to cart directory
local CART_ID = "firered_mod_test"
SaveData.setCart(CART_ID, "abc123hash")
local cartSlot = SaveData.createCartSlot(CART_ID)
SaveData.setActiveCartSlot(CART_ID, cartSlot)
eq(SaveData.saveFilename("firered"), "saves/cart_" .. CART_ID .. "/" .. cartSlot .. ".lua",
   "cart scope redirects saveFilename to cart directory")

-- Clearing cart scope restores base game slot
SaveData.setCart(nil)
eq(SaveData.saveFilename("firered"), "saves/firered/" .. slot1 .. ".lua",
   "clearing cart scope restores base game slot path")

-- Clean up slots
SaveData.deleteCartSlot(CART_ID, cartSlot)
SaveData.deleteSlot("firered", slot1)
SaveData.resetSlotState()

-- ---------------------------------------------------------------------------
-- 2. New Game Schema Defaults
-- ---------------------------------------------------------------------------
local session = Schema.newGame({ playerName = "RED", rivalName = "GREEN" })
check(type(session) == "table", "Schema.newGame returns a session table")
eq(session.name, "RED", "player name is RED")
eq(session.rivalName, "GREEN", "rival name is GREEN")
eq(session.money, 3000, "starting money is 3000")
eq(session.coins, 0, "starting coins is 0")
eq(#session.party, 0, "starting party is empty")
check(type(session.bag) == "table", "bag is initialized")
check(type(session.bag.pockets) == "table", "bag pockets are initialized")
check(session.trainerId >= 0 and session.trainerId <= 65535, "trainerId in 16-bit range")
check(session.secretId >= 0 and session.secretId <= 65535, "secretId in 16-bit range")
check(type(session.rng) == "table", "rng state is initialized")

local saveTable = Schema.toSaveTable(session)
check(type(saveTable) == "table", "Schema.toSaveTable succeeds")
eq(saveTable.engine, "game3", "saveTable engine is game3")
eq(saveTable.version, "firered", "saveTable version is firered")
eq(saveTable.name, "RED", "saveTable name matches")
check(type(saveTable.inventory) == "table", "saveTable has inventory compatibility alias")
check(type(saveTable.playTime) == "table", "saveTable has playTime table")

-- ---------------------------------------------------------------------------
-- 3. SaveData Migrations & Auto-healing
-- ---------------------------------------------------------------------------
-- Legacy save with missing engine or generation fields
local legacy1 = { version = "firered", map = "FR_PALLET_TOWN", name = "ASH" }
SaveData.runMigrations(legacy1)
eq(legacy1.engine, "game3", "runMigrations stamps engine = game3")
eq(legacy1.generation, 3, "runMigrations stamps generation = 3")
eq(legacy1.version, "firered", "runMigrations preserves version = firered")

-- Legacy save identified by FR_ map prefix
local legacy2 = { map = "FR_VIRIDIAN_CITY", name = "RED" }
SaveData.runMigrations(legacy2)
eq(legacy2.engine, "game3", "runMigrations stamps engine = game3 from map prefix")
eq(legacy2.generation, 3, "runMigrations stamps generation = 3 from map prefix")
eq(legacy2.version, "firered", "runMigrations fills default version = firered")

-- ---------------------------------------------------------------------------
-- 4. SaveData.slotSummary & Boot.continueInfoFromSave
-- ---------------------------------------------------------------------------
local testSave = {
  engine = "game3",
  version = "firered",
  generation = 3,
  name = "CHAMP",
  map = "FR_INDIGO_PLATEAU",
  playTime = { hours = 12, minutes = 34, seconds = 56 },
  dex = {
    owned = { [1] = true, [4] = true, [7] = true, [25] = true },
    seen = { [1] = true, [2] = true, [4] = true, [7] = true, [25] = true },
  },
  flags = {
    [0x820] = true, -- Boulder Badge
    [0x821] = true, -- Cascade Badge
    [0x822] = true, -- Thunder Badge
  },
}

local sumName, summary = SaveData.slotSummary(testSave)
eq(sumName, "CHAMP", "slotSummary extracts player name")
check(type(summary) == "table", "slotSummary returns summary table")
eq(summary.timeText, "12:34", "slotSummary formats timeText correctly")
eq(summary.dexCount, 4, "slotSummary counts owned dex species")
eq(summary.badges, 3, "slotSummary counts gym badges")

local cInfo = Boot.continueInfoFromSave(testSave)
check(type(cInfo) == "table", "Boot.continueInfoFromSave returns continue info")
eq(cInfo.name, "CHAMP", "continueInfo name matches")
eq(cInfo.hours, 12, "continueInfo hours matches")
eq(cInfo.minutes, 34, "continueInfo minutes matches")
eq(cInfo.dexCount, 4, "continueInfo dexCount matches")
eq(cInfo.badges, 3, "continueInfo badges count matches")

-- ---------------------------------------------------------------------------
-- 5. Full SaveData Save / Load Round-trip
-- ---------------------------------------------------------------------------
local slotForSave = SaveData.createSlot("firered")
SaveData.setActiveSlot("firered", slotForSave)

local okSave = SaveData.save(testSave)
eq(okSave, true, "SaveData.save successfully saved test save")

local loadedSave = SaveData.load("firered")
check(loadedSave ~= nil, "SaveData.load successfully reloaded test save")
eq(loadedSave.engine, "game3", "reloaded save has engine = game3")
eq(loadedSave.version, "firered", "reloaded save has version = firered")
eq(loadedSave.generation, 3, "reloaded save has generation = 3")
eq(loadedSave.name, "CHAMP", "reloaded save has name CHAMP")
eq(loadedSave.map, "FR_INDIGO_PLATEAU", "reloaded save has correct map")

local game3 = Game3.new()
eq(game3:_hasContinueSave(), true, "Game3:_hasContinueSave() is true for saved game")

GameVersion.set(priorVersion)
S.finish()
