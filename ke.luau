--[[
	KE - riftkeep roller

	rshift = open/close the menu

	packets live in ReplicatedStorage.Shared.Net (its a bytenet wrapper) so
	requestRoll / rollResult are just tables with .send/.listen on them.
	if the game ever moves that module, paste the new path in the snipe tab
	and hit rescan, dont bother editing the file

	config saves to ke_cfg.json if your executor has writefile
]]

-- services
local rs   = game:GetService("ReplicatedStorage")
local plr  = game:GetService("Players").LocalPlayer
local uis  = game:GetService("UserInputService")
local sg   = game:GetService("StarterGui")
local tw   = game:GetService("TweenService")
local http = game:GetService("HttpService")

-- config
local cfg = {
	target    = "Byte",
	banner    = "starter",
	multi     = true,
	delay     = 0,
	stopDrop  = true,
	stopBroke = true,
	alertOn   = true,
	alertMin  = 6,
	autostart = true,
	path      = "ReplicatedStorage.Shared.Net",
	verbose   = true,
	key       = "RightShift",
}

local function cost() return cfg.multi and 900 or 100 end

local RARITY = {"Common", "Rare", "Epic", "Legendary", "Mythic", "Rifted"}

local theme = {
	bg     = Color3.fromRGB(17, 17, 21),
	panel  = Color3.fromRGB(24, 24, 30),
	panel2 = Color3.fromRGB(32, 32, 40),
	line   = Color3.fromRGB(48, 48, 60),
	accent = Color3.fromRGB(124, 92, 255),
	blue   = Color3.fromRGB(92, 196, 255),
	text   = Color3.fromRGB(232, 232, 238),
	dim    = Color3.fromRGB(146, 146, 160),
	good   = Color3.fromRGB(110, 220, 150),
	warn   = Color3.fromRGB(255, 190, 90),
	bad    = Color3.fromRGB(255, 110, 110),
	off    = Color3.fromRGB(62, 62, 74),
}

-- state
local st = {
	bound = false, rolls = 0, pity = 0,
	essence = nil, running = false, waiting = false, scans = 0,
}

-- ui helpers, keep these at the top, everything below uses them
local function new(cls, props, parent)
	local o = Instance.new(cls)
	for k, v in next, props do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function round(o, r) new("UICorner", {CornerRadius = UDim.new(0, r or 6)}, o) end
local function outline(o, c, t) new("UIStroke", {Color = c or theme.line, Thickness = t or 1}, o) end
local function pad(o, n)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, n), PaddingRight = UDim.new(0, n),
		PaddingTop = UDim.new(0, n), PaddingBottom = UDim.new(0, n),
	}, o)
end

-- log
local MAXLOG = 120 -- dont go much higher or the log gets chuggy
local logBox, logScroll, lines = nil, nil, {}

local function log(msg, c)
	print("[ke] " .. msg)
	if not logBox then return end

	lines[#lines + 1] = new("TextLabel", {
		Size = UDim2.new(1, -6, 0, 15),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 12,
		TextColor3 = c or theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = ("[%s] %s"):format(os.date("%H:%M:%S"), msg),
	}, logBox)

	while #lines > MAXLOG do
		local old = table.remove(lines, 1)
		if old then old:Destroy() end
	end
	task.defer(function()
		if logScroll then logScroll.CanvasPosition = Vector2.new(0, 1e6) end
	end)
end

local function notify(title, text)
	task.spawn(function()
		local d = {Title = "ke", Text = title .. "  " .. text, Duration = 5}
		for _ = 1, 5 do
			if pcall(sg.SetCore, sg, "SendNotification", d) then return end
			task.wait(0.5)
		end
	end)
end

local catalog, catTried = nil, 0
local function nameOf(id)
	if not catalog and os.clock() - catTried > 5 then
		catTried = os.clock()
		local m = rs:FindFirstChild("Shared")
		m = m and m:FindFirstChild("Constants")
		m = m and m:FindFirstChild("WardenCatalog")
		if m then
			local ok, r = pcall(require, m)
			if ok and type(r) == "table" then catalog = r end
		end
	end
	local d = catalog and catalog[id]
	return (type(d) == "table" and d.name) or tostring(id)
end

-- net finding
-- bytenet packets are plain tables with .send/.listen so isPkt covers them
-- and the raw-remote fallback covers the case where nothing else loads
local SEND = {"requestroll", "rollrequest", "dorequestroll", "roll"}
local RECV = {"rollresult", "rollresults", "rollresponse", "result"}
local CUR  = {"currencyupdated", "currencyupdate", "updatedcurrency", "essence"}

local function scoreKey(k, list)
	k = k:lower()
	for i, w in next, list do if k == w then return 100 - i end end
	for i, w in next, list do if k:find(w, 1, true) then return 50 - i end end
	return 0
end

local function isRemote(v)
	return typeof(v) == "Instance"
		and (v:IsA("RemoteEvent") or v:IsA("UnreliableRemoteEvent") or v:IsA("RemoteFunction"))
end

local function isPkt(v)
	if isRemote(v) then return true end
	if type(v) ~= "table" then return false end
	return type(v.send) == "function" or type(v.Send) == "function"
		or type(v.fire) == "function" or type(v.Fire) == "function"
		or type(v.FireServer) == "function"
		or type(v.listen) == "function" or type(v.Listen) == "function"
		or type(v.connect) == "function" or type(v.Connect) == "function"
		or typeof(v.OnClientEvent) == "RBXScriptSignal"
end

local function searchTbl(t, list, d, seen)
	seen = seen or {}
	if d > 3 or seen[t] then return nil, 0, nil end
	seen[t] = true

	local best, bs, bk
	for k, v in next, t do
		if type(k) == "string" and isPkt(v) then
			local s = scoreKey(k, list)
			if s > (bs or 0) then best, bs, bk = v, s, k end
		end
	end
	if best then return best, bs, bk end

	for k, v in next, t do
		if type(k) == "string" and type(v) == "table" and not isPkt(v) then
			local f, s, key = searchTbl(v, list, d + 1, seen)
			if f and s > (bs or 0) then best, bs, bk = f, s, key end
		end
	end
	return best, bs, bk
end

local PATHS = {
	"ReplicatedStorage.Shared.Net",
	"ReplicatedStorage.Shared.Packages.Net",
	"ReplicatedStorage.Shared.Networking",
	"ReplicatedStorage.Shared.Packages.ByteNet",
	"ReplicatedStorage.Net",
}
local NAMES   = {"Net", "Network", "Networking", "Packets", "Remotes", "Bridge", "Signal"}
local HOLDERS = {"Shared", "Packages", "Modules", "Lib", "Libraries", "Framework", "Core", "Common"}

local cands, candTime = {}, 0

local function dig(inst, path)
	local node = inst
	for part in path:gmatch("[^%.]+") do
		node = node:FindFirstChild(part)
		if not node then return nil end
	end
	return node
end

local function buildCands()
	if os.clock() - candTime < 5 and #cands > 0 then return cands end
	candTime = os.clock()

	local list, seen = {}, {}
	local function add(i)
		if i and i:IsA("ModuleScript") and not seen[i] then
			seen[i] = true
			list[#list + 1] = i
		end
	end

	for _, p in next, PATHS do add(dig(game, p)) end
	for _, n in next, NAMES do add(rs:FindFirstChild(n)) end
	for _, h in next, HOLDERS do
		local root = rs:FindFirstChild(h)
		if root then
			for _, n in next, NAMES do add(root:FindFirstChild(n)) end
			for _, c in next, root:GetChildren() do
				for _, n in next, NAMES do add(c:FindFirstChild(n)) end
			end
		end
	end
	for _, d in next, rs:GetDescendants() do
		if d:IsA("ModuleScript") then
			local n = d.Name:lower()
			if n:find("net", 1, true) or n:find("packet", 1, true) or n:find("remote", 1, true) then
				add(d)
			end
		end
	end
	for _, d in next, rs:GetDescendants() do
		if d:IsA("ModuleScript") then add(d) end
	end

	cands = list
	return list
end

local tried, toldOff = {}, {}

local function tryMod(m)
	local now = os.clock()
	if tried[m] and now - tried[m] < 5 then return nil, nil end
	tried[m] = now

	local ok, r = pcall(require, m)
	if not ok then return nil, "require failed: " .. tostring(r) end
	if type(r) ~= "table" then return nil, "returns " .. typeof(r) end

	local send, ss, sk = searchTbl(r, SEND, 1)
	if not send or ss <= 0 then return nil, "no roll packet" end

	local recv, rsco, rk = searchTbl(r, RECV, 1)
	local cur, cs, ck = searchTbl(r, CUR, 1)

	return {
		mod = m, send = send, sk = sk,
		recv = recv, rk = rk, cur = cur, ck = ck,
		score = ss * 3 + (rsco or 0) * 2 + (cs or 0),
	}, nil
end

local function discover()
	if cfg.path ~= "" then
		local m = dig(game, cfg.path)
		if m and m:IsA("ModuleScript") then
			local r, why = tryMod(m)
			if r then return r end
			if why and cfg.verbose and not toldOff[m] then
				toldOff[m] = true
				log("skipped " .. m:GetFullName() .. " (" .. why .. ")", theme.dim)
			end
		end
	end

	local best
	for i, m in next, buildCands() do
		local r, why = tryMod(m)
		if r then
			if not best or r.score > best.score then best = r end
			if best.score >= 150 then break end
		elseif why and cfg.verbose and not toldOff[m] then
			local n = m.Name:lower()
			if n:find("net", 1, true) or n:find("roll", 1, true) or n:find("packet", 1, true) then
				toldOff[m] = true
				log("skipped " .. m:GetFullName() .. " (" .. why .. ")", theme.dim)
			end
		end
		if i % 20 == 0 then task.wait() end
	end
	return best
end

local function scanRemotes()
	local s, r, c, ss, rr, cc = nil, nil, nil, 0, 0, 0
	for _, d in next, rs:GetDescendants() do
		if d:IsA("RemoteEvent") or d:IsA("UnreliableRemoteEvent") then
			local n = d.Name:lower()
			local a, b, e = scoreKey(n, SEND), scoreKey(n, RECV), scoreKey(n, CUR)
			if b > rr then r, rr = d, b end
			if a > ss then s, ss = d, a end
			if e > cc then c, cc = d, e end
		end
	end
	return s, r, c
end

-- binding
local function wantsSelf(f)
	local ok, n, va = pcall(debug.info, f, "a")
	if ok and type(n) == "number" then return n >= 2 or (n == 1 and va == true) end
	return false
end

local function firer(pkt)
	if isRemote(pkt) then
		if pkt:IsA("RemoteFunction") then
			return function(d) return pcall(pkt.InvokeServer, pkt, d) end
		end
		return function(d)
			local ok, err = pcall(pkt.FireServer, pkt, d)
			if not ok then ok, err = pcall(pkt.FireServer, pkt, d.bannerId, d.multi) end
			return ok, err
		end
	end
	if type(pkt) ~= "table" then return nil end
	local f = pkt.send or pkt.Send or pkt.fire or pkt.Fire or pkt.FireServer
	if type(f) ~= "function" then return nil end
	if wantsSelf(f) then return function(d) return pcall(f, pkt, d) end end
	return function(d) return pcall(f, d) end
end

local function listen(pkt, cb)
	if isRemote(pkt) then
		if pkt:IsA("RemoteEvent") or pkt:IsA("UnreliableRemoteEvent") then
			pkt.OnClientEvent:Connect(cb)
			return true
		end
		return false
	end
	if type(pkt) ~= "table" then return false end
	local f = pkt.listen or pkt.Listen or pkt.connect or pkt.Connect or pkt.on or pkt.On
	if type(f) ~= "function" then
		if typeof(pkt.OnClientEvent) == "RBXScriptSignal" then
			pkt.OnClientEvent:Connect(cb)
			return true
		end
		return false
	end
	if wantsSelf(f) then pcall(f, pkt, cb) else pcall(f, cb) end
	return true
end

local net = {fire = nil, onResult = nil, onCurrency = nil, mode = "", where = "-"}

local function bindMod(f)
	local f2 = firer(f.send)
	if not f2 then return false end
	net.mode, net.where, net.fire = "module", f.mod:GetFullName(), f2
	log("bound " .. net.where, theme.good)
	log("  send -> " .. f.mod.Name .. "." .. tostring(f.sk), theme.dim)
	if f.recv then
		log("  recv -> " .. f.mod.Name .. "." .. tostring(f.rk), theme.dim)
		listen(f.recv, function(d) if net.onResult then net.onResult(d) end end)
	else
		log("  no result packet, rolls wont be logged", theme.warn)
	end
	if f.cur then
		listen(f.cur, function(d) if net.onCurrency then net.onCurrency(d) end end)
	end
	return true
end

local function bindRemote()
	local s, r, c = scanRemotes()
	if not s then return false end
	local f = firer(s)
	if not f then return false end
	net.mode, net.where, net.fire = "remote", s:GetFullName(), f
	log("bound remotes " .. net.where, theme.warn)
	if r then listen(r, function(d) if net.onResult then net.onResult(d) end end) end
	if c then listen(c, function(d) if net.onCurrency then net.onCurrency(d) end end) end
	return true
end

-- results
local dumped = false

local function onResult(d)
	st.waiting = false
	if type(d) ~= "table" then return end

	if not dumped then
		dumped = true
		local ks = {}
		for k in next, d do ks[#ks + 1] = tostring(k) end
		table.sort(ks)
		log("result fields: " .. table.concat(ks, ", "), theme.dim)
	end

	if type(d.bannerId) == "string" and d.bannerId ~= "" then cfg.banner = d.bannerId end
	if type(d.pityCounter) == "number" then st.pity = d.pityCounter end

	local ids = d.wardenIds or d.wardenId or d.ids or {}
	if type(ids) ~= "table" then ids = {ids} end
	local rar = d.rarityIds or d.rarityId or {}
	if type(rar) ~= "table" then rar = {rar} end
	local uids = d.uids or d.uid or {}
	if type(uids) ~= "table" then uids = {uids} end

	local out = {}
	for i, id in next, ids do
		out[#out + 1] = nameOf(id) .. " [" .. (RARITY[rar[i]] or "?") .. "]"
	end

	st.rolls = st.rolls + #ids
	log(("roll %d  pity %s/100  %s"):format(st.rolls, tostring(st.pity),
		#out > 0 and table.concat(out, ", ") or "-"))

	for i, id in next, ids do
		local r = rar[i] or 0
		if id == cfg.target then
			local uid = tostring(uids[i] or "?")
			log((">>> %s  uid %s  roll %d"):format(cfg.target, uid, st.rolls), theme.good)
			notify(cfg.target .. " rolled", "uid " .. uid)
			if cfg.stopDrop then st.running = false end
		elseif cfg.alertOn and r >= cfg.alertMin then
			log("  rifted: " .. nameOf(id), theme.blue)
			notify("rifted: " .. nameOf(id), "roll " .. st.rolls)
		end
	end
end

net.onResult = onResult

net.onCurrency = function(d)
	if type(d) == "table" and type(d.essence) == "number" then
		st.essence = d.essence
	elseif type(d) == "number" then
		st.essence = d
	end
end

-- engine
local function roll()
	if not net.fire then return false end
	st.waiting = true
	local ok, err = net.fire({bannerId = cfg.banner, multi = cfg.multi})
	if not ok then
		st.waiting = false
		log("send failed: " .. tostring(err), theme.bad)
	end
	return ok
end

local function start()
	if st.running or not net.fire then return end
	st.running = true
	log("started  target=" .. cfg.target .. "  cost=" .. cost(), theme.blue)

	task.spawn(function()
		while st.running do
			if cfg.stopBroke and st.essence and st.essence < cost() then
				st.running = false
				log("out of essence after " .. st.rolls, theme.warn)
				notify("out of essence", "stopped")
				break
			end
			roll()
			local t = os.clock()
			while st.running and st.waiting and os.clock() - t < 2 do task.wait(0.05) end
			if st.running and cfg.delay > 0 then task.wait(cfg.delay) end
		end
		log("stopped", theme.dim)
	end)
end

local function stop() st.running = false end

-- config file
local file = "ke_cfg.json"
local saving = false

local function saveCfg()
	if not writefile or saving then return end
	saving = true
	task.delay(1, function()
		saving = false
		pcall(function() writefile(file, http:JSONEncode(cfg)) end)
	end)
end

local function loadCfg()
	if not (isfile and readfile and isfile(file)) then return end
	local ok, data = pcall(function() return http:JSONDecode(readfile(file)) end)
	if not ok or type(data) ~= "table" then return end
	for k, v in next, data do
		if cfg[k] ~= nil then cfg[k] = v end
	end
end

loadCfg()

local function setopt(k, v)
	cfg[k] = v
	saveCfg()
end

-- ui
local okHui, hui = pcall(function() return gethui() end)
local guiParent = (okHui and hui) or game:GetService("CoreGui")

local gui = new("ScreenGui", {
	Name = "ke_menu",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 999,
}, guiParent)

local win = new("Frame", {
	Name = "win",
	Size = UDim2.fromOffset(420, 356),
	Position = UDim2.fromOffset(60, 90),
	BackgroundColor3 = theme.bg,
	BorderSizePixel = 0,
}, gui)
round(win, 8)
outline(win)

local top = new("Frame", {
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundColor3 = theme.panel,
	BorderSizePixel = 0,
}, win)
round(top, 8)
new("Frame", {
	Size = UDim2.new(1, 0, 0, 8),
	Position = UDim2.new(0, 0, 1, -8),
	BackgroundColor3 = theme.panel,
	BorderSizePixel = 0,
}, top)

local bar = new("Frame", {
	Size = UDim2.fromOffset(3, 14),
	Position = UDim2.fromOffset(10, 8),
	BackgroundColor3 = theme.accent,
	BorderSizePixel = 0,
}, top)
round(bar, 2)

new("TextLabel", {
	Size = UDim2.new(1, -110, 1, 0),
	Position = UDim2.fromOffset(20, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	Text = "KE  ·  riftkeep",
	TextColor3 = theme.text,
	TextXAlignment = Enum.TextXAlignment.Left,
}, top)

local close = new("TextButton", {
	Size = UDim2.fromOffset(22, 22),
	Position = UDim2.new(1, -26, 0, 4),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	Text = "x",
	TextColor3 = theme.dim,
}, top)

-- drag
do
	local held, start, origin = false, nil, nil
	top.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then
			held, start, origin = true, i.Position, win.Position
		end
	end)
	uis.InputChanged:Connect(function(i)
		if not held then return end
		if i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch then
			win.Position = UDim2.new(
				origin.X.Scale, origin.X.Offset + (i.Position.X - start.X),
				origin.Y.Scale, origin.Y.Offset + (i.Position.Y - start.Y))
		end
	end)
	uis.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then held = false end
	end)
end

local tabRow = new("Frame", {
	Size = UDim2.new(1, -16, 0, 22),
	Position = UDim2.fromOffset(8, 36),
	BackgroundTransparency = 1,
}, win)
new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4)}, tabRow)

local body = new("Frame", {
	Size = UDim2.new(1, -16, 1, -102),
	Position = UDim2.fromOffset(8, 62),
	BackgroundTransparency = 1,
}, win)

local pages, pageBtns = {}, {}
local selectTab

local function tab(name)
	local b = new("TextButton", {
		Size = UDim2.fromOffset(72, 22),
		BackgroundColor3 = theme.panel2,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		Text = name,
		TextColor3 = theme.dim,
	}, tabRow)
	round(b, 5)
	pageBtns[name] = b

	local p = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	}, body)
	new("UIListLayout", {Padding = UDim.new(0, 2)}, p)
	pages[name] = p

	b.MouseButton1Click:Connect(function() selectTab(name) end)
	return p
end

selectTab = function(name)
	for n, p in next, pages do p.Visible = n == name end
	for n, b in next, pageBtns do
		b.BackgroundColor3 = n == name and theme.accent or theme.panel2
		b.TextColor3 = n == name and theme.text or theme.dim
	end
end

local function toggle(p, text, get, set)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, p)

	local lbl = new("TextLabel", {
		Size = UDim2.new(1, -44, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		Text = text,
		TextColor3 = theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)

	local pill = new("Frame", {
		Size = UDim2.fromOffset(32, 17),
		Position = UDim2.new(1, -34, 0.5, -8),
		BackgroundColor3 = theme.off,
		BorderSizePixel = 0,
	}, row)
	round(pill, 9)

	local dot = new("Frame", {
		Size = UDim2.fromOffset(13, 13),
		Position = UDim2.fromOffset(2, 2),
		BackgroundColor3 = theme.text,
		BorderSizePixel = 0,
	}, pill)
	round(dot, 7)

	local function paint(on)
		tw:Create(pill, TweenInfo.new(0.12), {BackgroundColor3 = on and theme.accent or theme.off}):Play()
		tw:Create(dot, TweenInfo.new(0.12), {
			Position = on and UDim2.fromOffset(17, 2) or UDim2.fromOffset(2, 2),
		}):Play()
	end

	paint(get())
	row.MouseButton1Click:Connect(function()
		local v = not get()
		set(v)
		paint(v)
	end)

	return {label = lbl, paint = paint}
end

local function slider(p, text, min, max, step, get, set)
	local row = new("Frame", {Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1}, p)

	new("TextLabel", {
		Size = UDim2.new(1, -50, 0, 15),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		Text = text,
		TextColor3 = theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)

	local val = new("TextLabel", {
		Size = UDim2.new(0, 50, 0, 15),
		Position = UDim2.new(1, -50, 0, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 12,
		Text = "",
		TextColor3 = theme.blue,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, row)

	local hit = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.new(0, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, row)

	local track = new("Frame", {
		Size = UDim2.new(1, 0, 0, 4),
		Position = UDim2.new(0, 0, 0.5, -2),
		BackgroundColor3 = theme.off,
		BorderSizePixel = 0,
	}, hit)
	round(track, 2)

	local fill = new("Frame", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = theme.accent,
		BorderSizePixel = 0,
	}, track)
	round(fill, 2)

	local knob = new("Frame", {
		Size = UDim2.fromOffset(10, 10),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = theme.text,
		BorderSizePixel = 0,
	}, track)
	round(knob, 5)

	local function paint(v)
		local a = max == min and 0 or (v - min) / (max - min)
		fill.Size = UDim2.new(a, 0, 1, 0)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
		val.Text = tostring(v)
	end
	paint(get())

	local held = false
	local function grab(i)
		local rel = math.clamp((i.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local v = math.clamp(math.floor((min + rel * (max - min)) / step + 0.5) * step, min, max)
		set(v)
		paint(v)
	end

	hit.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then
			held = true
			grab(i)
		end
	end)
	uis.InputChanged:Connect(function(i)
		if held and (i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch) then grab(i) end
	end)
	uis.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then held = false end
	end)
end

local function input(p, text, get, set)
	local row = new("Frame", {Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1}, p)

	new("TextLabel", {
		Size = UDim2.new(1, -50, 0, 15),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		Text = text,
		TextColor3 = theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)

	local box = new("TextBox", {
		Size = UDim2.new(1, 0, 0, 17),
		Position = UDim2.new(0, 0, 0, 15),
		BackgroundColor3 = theme.panel2,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		TextSize = 12,
		Text = get(),
		TextColor3 = theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
	}, row)
	pad(box, 4)
	round(box, 4)
	outline(box, theme.line)

	box.FocusLost:Connect(function() set(box.Text) end)
	return box
end

local function button(p, text, c, fn)
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 25),
		BackgroundColor3 = c,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		Text = text,
		TextColor3 = theme.text,
	}, p)
	round(b, 5)
	b.MouseButton1Click:Connect(fn)
	return b
end

-- main tab
local pg = tab("main")
toggle(pg, "auto roll", function() return st.running end, function(v)
	if v then start() else stop() end
end)
toggle(pg, "auto start", function() return cfg.autostart end, function(v) setopt("autostart", v) end)

local multiT = toggle(pg, "multi roll (" .. cost() .. ")", function() return cfg.multi end, function(v)
	setopt("multi", v)
	multiT.label.Text = "multi roll (" .. cost() .. ")"
end)

toggle(pg, "stop on drop", function() return cfg.stopDrop end, function(v) setopt("stopDrop", v) end)
toggle(pg, "stop when broke", function() return cfg.stopBroke end, function(v) setopt("stopBroke", v) end)
toggle(pg, "rarity alerts", function() return cfg.alertOn end, function(v) setopt("alertOn", v) end)

local brow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 28),
	Position = UDim2.new(0, 0, 0, 194),
	BackgroundTransparency = 1,
}, pg)
new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6)}, brow)

button(brow, "start", theme.accent, start).Size = UDim2.new(0.31, 0, 1, 0)
button(brow, "stop", theme.panel2, stop).Size = UDim2.new(0.31, 0, 1, 0)
button(brow, "roll 1", theme.panel2, function() roll() end).Size = UDim2.new(0.31, 0, 1, 0)

-- snipe tab
local pg2 = tab("snipe")
input(pg2, "target", function() return cfg.target end, function(v)
	if v ~= "" then setopt("target", v) end
end)
input(pg2, "banner", function() return cfg.banner end, function(v)
	if v ~= "" then setopt("banner", v) end
end)
slider(pg2, "alert rarity", 1, 6, 1, function() return cfg.alertMin end, function(v) cfg.alertMin = v end)
slider(pg2, "delay", 0, 2, 0.05, function() return cfg.delay end, function(v) cfg.delay = v end)
input(pg2, "module path", function() return cfg.path end, function(v) setopt("path", v) end)

local brow2 = new("Frame", {
	Size = UDim2.new(1, 0, 0, 28),
	Position = UDim2.new(0, 0, 0, 194),
	BackgroundTransparency = 1,
}, pg2)
new("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6)}, brow2)

button(brow2, "rescan", theme.panel2, function()
	tried, toldOff = {}, {}
	candTime = 0
	net.fire = nil
	st.bound = false
	log("rescan", theme.warn)
end).Size = UDim2.new(0.48, 0, 1, 0)

button(brow2, "test fire", theme.panel2, function()
	if not net.fire then log("nothing bound yet", theme.bad) return end
	local ok, err = net.fire({bannerId = cfg.banner, multi = false})
	log(ok and "test fire sent" or ("test fire failed: " .. tostring(err)),
		ok and theme.good or theme.bad)
end).Size = UDim2.new(0.48, 0, 1, 0)

-- log tab
local pg3 = tab("log")
logScroll = new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = theme.accent,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
}, pg3)
new("UIListLayout", {Padding = UDim.new(0, 1)}, logScroll)
logBox = logScroll

-- footer
local foot = new("Frame", {
	Size = UDim2.new(1, -16, 0, 28),
	Position = UDim2.new(0, 8, 1, -32),
	BackgroundColor3 = theme.panel,
	BorderSizePixel = 0,
}, win)
round(foot, 5)

local statusLbl = new("TextLabel", {
	Size = UDim2.new(1, -80, 1, 0),
	Position = UDim2.fromOffset(6, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextSize = 11,
	Text = "booting",
	TextColor3 = theme.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
}, foot)

new("TextLabel", {
	Size = UDim2.fromOffset(70, 1),
	Position = UDim2.new(1, -76, 0.5, -6),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextSize = 10,
	Text = cfg.key .. " = hide",
	TextColor3 = theme.dim,
	TextXAlignment = Enum.TextXAlignment.Right,
}, foot)

local statusDot = new("Frame", {
	Size = UDim2.fromOffset(7, 7),
	Position = UDim2.new(1, -14, 0.5, -3),
	BackgroundColor3 = theme.bad,
	BorderSizePixel = 0,
}, foot)
round(statusDot, 4)

-- pill that shows up when the window is closed
local pill = new("TextButton", {
	Size = UDim2.fromOffset(44, 22),
	Position = UDim2.fromOffset(14, 120),
	BackgroundColor3 = theme.panel,
	BorderSizePixel = 0,
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	Text = "ke",
	TextColor3 = theme.accent,
	Visible = false,
}, gui)
round(pill, 6)
outline(pill)

close.MouseButton1Click:Connect(function()
	win.Visible = false
	pill.Visible = true
end)

pill.MouseButton1Click:Connect(function()
	win.Visible = true
	pill.Visible = false
end)

selectTab("main")

-- keybind
local key = Enum.KeyCode[cfg.key] or Enum.KeyCode.RightShift
uis.InputBegan:Connect(function(i)
	if i.KeyCode ~= key then return end
	win.Visible = not win.Visible
	pill.Visible = not win.Visible
end)

-- boot
log("loaded, hunting for the net module")

task.spawn(function()
	local didStart = false
	while true do
		task.wait(1.5)
		if not st.bound then
			st.scans = st.scans + 1
			local ok, found = pcall(discover)
			if ok and found and bindMod(found) then
				st.bound = true
			else
				local ok2, bound = pcall(bindRemote)
				if ok2 and bound then st.bound = true end
			end
			if not st.bound and (st.scans <= 3 or st.scans % 6 == 0) then
				log("scan " .. st.scans .. " - nothing yet", theme.dim)
			end
		end
		if st.bound and not didStart and cfg.autostart then
			didStart = true
			task.wait(0.5)
			start()
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(0.4)
		if st.bound then
			statusLbl.Text = ("%s | rolls %d | pity %d | %s"):format(
				net.mode, st.rolls, st.pity,
				st.essence and ("essence " .. math.floor(st.essence)) or "essence ?")
			statusDot.BackgroundColor3 = st.running and theme.good or theme.accent
		else
			statusLbl.Text = "scanning (" .. st.scans .. ")"
			statusDot.BackgroundColor3 = theme.bad
		end
	end
end)

getgenv().ke = {
	cfg = cfg,
	net = net,
	start = start,
	stop = stop,
	roll = roll,
}
