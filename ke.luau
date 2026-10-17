--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local CONFIG = {
	target = "Byte",
	banner = "starter",
	multi = true,        -- 900 for 10 beats 1000 for 10 singles
	delay = 0,
	stopOnDrop = true,
	stopWhenBroke = true,
	alertRarity = 6,     -- ping on any other Rifted, not just Byte
	autoStart = true,
}

local COST = CONFIG.multi and 900 or 100

local RARITY = {[1] = "Common", [2] = "Rare", [3] = "Epic", [4] = "Legendary", [5] = "Mythic", [6] = "Rifted"}

local function isNet(v)
	return type(v) == "table" and type(v.requestRoll) == "table" and type(v.rollResult) == "table"
end

local function try(mod)
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok and isNet(res) then return res end
	end
end

local Net
for _, n in ipairs({"Net", "Network", "Packets", "Remotes", "Networking"}) do
	Net = try(ReplicatedStorage:FindFirstChild(n))
	if Net then break end
end

if not Net then
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d:IsA("ModuleScript") then
			local n = d.Name:lower()
			if n:find("net") or n:find("packet") or n:find("remote") then
				Net = try(d)
				if Net then break end
			end
		end
	end
end

assert(Net, "couldn't find the Net module")

-- 0.4 sends as packet.send(data), some forks pass the packet first
local SELF = false
do
	local ok, n = pcall(debug.info, Net.requestRoll.send, "a")
	SELF = ok and type(n) == "number" and n >= 2
end

local function fire(packet, data)
	if SELF then return pcall(packet.send, packet, data) end
	return pcall(packet.send, data)
end

local function on(packet, cb)
	if SELF then return pcall(packet.listen, packet, cb) end
	return pcall(packet.listen, cb)
end

local Catalog
do
	local ok, res = pcall(require, ReplicatedStorage.Shared.Constants.WardenCatalog)
	if ok and type(res) == "table" then Catalog = res end
end

local function label(id)
	local def = Catalog and Catalog[id]
	return def and def.name or id
end

local running = false
local pending = false
local rolls = 0
local essence = math.huge

local function notify(title, text)
	pcall(function()
		StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = 6})
	end)
end

on(Net.currencyUpdated, function(d)
	if type(d) == "table" and type(d.essence) == "number" then
		essence = d.essence
	end
end)

on(Net.rollResult, function(d)
	pending = false
	if type(d) ~= "table" then return end
	if type(d.bannerId) == "string" then CONFIG.banner = d.bannerId end

	local ids = d.wardenIds or {}
	local rar = d.rarityIds or {}
	local uids = d.uids or {}

	local parts = {}
	for i, id in ipairs(ids) do
		local r = rar[i] or 0
		parts[i] = ("%s [%s]"):format(label(id), RARITY[r] or tostring(r))
	end

	rolls += #ids
	print(("[%d] pity %s | essence %s | %s"):format(
		rolls,
		tostring(d.pityCounter) .. "/100",
		essence == math.huge and "?" or tostring(math.floor(essence)),
		table.concat(parts, ", ")
	))

	for i, id in ipairs(ids) do
		local r = rar[i] or 0
		if id == CONFIG.target then
			local uid = tostring(uids[i])
			print((">>> %s | uid %s | roll %d"):format(CONFIG.target, uid, rolls))
			notify(CONFIG.target .. " rolled", "uid " .. uid)
			if CONFIG.stopOnDrop then running = false end
		elseif r >= CONFIG.alertRarity then
			notify("Rifted: " .. label(id), "roll " .. tostring(rolls))
		end
	end
end)

local KE = {}
KE.config = CONFIG

function KE.roll()
	pending = true
	local ok = fire(Net.requestRoll, {bannerId = CONFIG.banner, multi = CONFIG.multi})
	if not ok then pending = false end
	return ok
end

function KE.start()
	if running then return end
	running = true
	task.spawn(function()
		while running do
			if CONFIG.stopWhenBroke and essence < COST then
				running = false
				notify("Out of essence", "stopped after " .. tostring(rolls))
				print("[KE] out of essence after " .. tostring(rolls) .. " rolls")
				break
			end

			KE.roll()

			local t = os.clock()
			while running and pending and os.clock() - t < 2 do
				task.wait(0.05)
			end
			if running and CONFIG.delay > 0 then task.wait(CONFIG.delay) end
		end
	end)
end

function KE.stop()
	running = false
end

local env = getgenv and getgenv() or _G
env.KE = KE

if CONFIG.autoStart then KE.start() end

print(("[KE] sniping %s on %s | multi=%s | %d essence per request"):format(
	CONFIG.target, CONFIG.banner, tostring(CONFIG.multi), COST
))
return KE
