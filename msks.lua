--- Modern Simple Krist Shop

-- This is a simple implementation of a Krist shop.
-- See the github or config.lua and listings.lua for details.

-- Copyright 2022 Mason Gulu
-- Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


local configFile = assert(fs.open("config.lua", "r"), "Unable to open config file!")
local config = assert(textutils.unserialise(configFile.readAll()), "Unable to unserialize config")
configFile.close()

assert(config.address and config.address ~= "", "Config sets no address!")
assert(config.privateKey and config.privateKey ~= "", "Config sets no private key!")
assert(#config.inventories > 0, "Config provides no inventories")
local monitor = peripheral.wrap(config.monitor)
assert(monitor, "Config provides invalid monitor")
assert(config.turtle and config.turtle ~= "", "Config provides no turtle address on network")


local krist = require("ktwsl")(config.kristEndpoint, config.privateKey)

local listingFile = assert(fs.open("listings.lua", "r"), "Unable to open listings file")
local listings = assert(textutils.unserialise(listingFile.readAll()), "Unable to unserialize listings")
listingFile.close()

local invCache = require("abstractInvLib")(config.inventories)

-- TODO Provide program to generate listings for you!

local theme = {
  bg = colors.black,
  text = colors.white,
  atext = colors.gray,
  banner = colors.yellow,
  bannerText = colors.orange,
  err = colors.red
}

local function setPalette(d)
  d.setPaletteColor(theme.bg, config.theme.background)
  d.setPaletteColor(theme.text, config.theme.primaryText)
  d.setPaletteColor(theme.atext, config.theme.secondaryText)
  d.setPaletteColor(theme.banner, config.theme.bannerColor)
  d.setPaletteColor(theme.err, config.theme.errorColor)
  d.setPaletteColor(theme.bannerText, config.theme.bannerText)
end

if config.applyThemeToTerm then
  setPalette(term)
end
setPalette(monitor)

local speaker = peripheral.wrap(config.speaker)
local function playSound(sound)
  if speaker then
    speaker.playSound(sound)
  end
end

--- Validate and create lookup table
local listingAddressLUT = {}
for k,v in ipairs(listings) do
  local address
  if v.address then
    -- Has a custom address
    assert(v.address ~= "", "Item "..v.label.." attempts to set no address!")
    address = v.address
  else
    -- Has no custom address, and no name, so use default address
    assert(config.address ~= "", "Default address is empty")
    address = config.address
  end
  v.count = 0
  listingAddressLUT[address] = listingAddressLUT[address] or {}
  local nameToUse
  -- If v.name is set, then v.metaname and v.address are BOTH required
  -- If v.name is not set, then use config.name
  -- If v.name is an empty string, do not use a name
  -- If v.metaname is set, then either v.address or config.address is required
  -- If v.metaname is not set, or is an empty string, assert that a name is not being used
  if v.name and v.name ~= "" then
    -- Has a custom name
    assert(v.address, "Item "..v.label.." has a custom name, but no address")
    assert(v.address ~= "", "Item "..v.label.." has a custom name, but an empty address")
    nameToUse = v.name
  elseif (v.name ~= "") and config.name and config.name ~= "" then
    -- Uses the default name
    nameToUse = config.name
  end
  v.address = address
  if nameToUse then
    assert(v.metaname, "Item "..v.label.." has a name, but no metaname")
    assert(v.metaname ~= "", "Item "..v.label.." has a name, but an empty metaname")
    v.name = nameToUse
    v.sendTo = v.metaname.."@"..v.name..".kst"
    assert(not listingAddressLUT[address][v.metaname], "Duplicate metaname for item "..v.label.." "..nameToUse)
    listingAddressLUT[address][v.metaname] = v
  else
    v.sendTo = address
    listingAddressLUT[address].noName = v
  end
end

monitor.bg = monitor.setBackgroundColor
monitor.fg = monitor.setTextColor
monitor.c = monitor.setCursorPos

local function drawMonitor()
  monitor.setTextScale(0.5)
  monitor.bg(theme.bg)
  monitor.clear()
  -- top banner
  monitor.bg(theme.banner)
  monitor.fg(theme.bannerText)
  monitor.c(1,1)
  monitor.clearLine()
  monitor.write(config.shopName)
  monitor.c(1,2)
  monitor.clearLine()
  monitor.write("Shop owned by "..config.contactName)
  monitor.c(1,3)
  monitor.clearLine()

  local space = math.floor((({monitor.getSize()})[1] - 14) / 2)
  local formatStr = "%-5s|%-"..space.."s|%-"..space.."s|%-5s"
  monitor.write(string.format(formatStr, "Stock", "Name", "Address", "KST/I"))

  monitor.bg(theme.bg)
  monitor.fg(theme.text)
  -- TODO get the rest of this setup
  for k, v in pairs(listings) do
    if (k % 2) == 1 then
      monitor.fg(theme.atext)
    else
      monitor.fg(theme.text)
    end
    monitor.setCursorPos(1, k + 3)
    monitor.write(string.format(formatStr, invCache.getCount(v.id), v.label, v.sendTo, v.price))
  end
end



--- This function is only called if the purchase is to a valid listing
local function handlePurchase(listing, event)
  local itemsToDispense = math.floor(event.value / listing.price)
  local itemsDispensed = invCache.pushItems(config.turtle, listing.id, itemsToDispense, nil, function()
    playSound(config.sounds.itemDispensed)
    turtle.drop()
  end)
  os.queueEvent("rerender")

  local refund = math.floor(event.value - (itemsDispensed * listing.price))

  if refund > 0 then
    -- TODO process refund
    local refundMsg = {
      to = event.from,
      type = "make_transaction",
      privatekey = config.privateKey,
      amount = refund
    }
    if event.metadata then
      local meta = krist.parseMetadata(event.metadata)
      if (meta["return"]) then
        refundMsg.metadata = meta["return"]
        refundMsg.to = meta["return"]
      end
    end
    local refundStatus = krist.wsReq(refundMsg)
    playSound(config.sounds.refundIssued)
    assert(refundStatus.ok, "Error refunding"..event.from..": "..(refundStatus["error"] or "?"))
  else
    playSound(config.sounds.saleSuccess)
  end
end

krist.setTransactionHandler(function(event)
  if event.event == "transaction" then
    event = event.transaction
    if listingAddressLUT[event.to] then
      -- this is an address we're interested in transactions to
      if event.sent_name then
        -- this is a transaction with a name involved
        local listing = listingAddressLUT[event.to][event.sent_metaname]
        if listing and listing.name == event.sent_name then
          handlePurchase(listing, event)
        end -- if this doesn't execute, then the purchase was to a name we don't care about
        -- TODO log if this doesn't execute
      else
        -- this is a transaction without a name involved
        local listing = listingAddressLUT[event.to].noName
        if listing then
          handlePurchase(listing, event)
        end -- if this doesn't execute then we're not listening for transactions on this address
        -- TODO log if this doesn't execute
      end
    end
  end
end)

invCache.refreshStorage()

local exitReason = krist.start(function()
  while true do
    drawMonitor()
    os.pullEvent("rerender")
  end
end)

monitor.bg(theme.bg)
monitor.fg(theme.err)
local errStartLine = 3
monitor.c(1,errStartLine+1)
monitor.write("WARNING")
monitor.c(1,errStartLine+2)
monitor.write("This shop has stopped listening for Krist events")
monitor.c(1,errStartLine+3)
monitor.write("Please report this to the shop owner/github")
monitor.c(1,errStartLine+4)
monitor.write("https://github.com/MasonGulu/msks")
monitor.c(1,errStartLine+5)
monitor.write("Supply this exit reason: ")
monitor.c(1,errStartLine+6)
monitor.write(exitReason)