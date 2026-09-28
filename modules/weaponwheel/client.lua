if not lib then return end

-- Weapon wheel for hotbar slots 1-5, replaces the hotbar popup on the hotbar keybind (TAB).
-- Kept in its own module so upstream ox_inventory updates can be merged with minimal conflicts.
--
-- Handling works like the GTA weapon wheel: the nui never takes focus, so the player keeps
-- moving while the wheel is open. Camera, aiming and shooting are blocked and the mouse
-- movement picks the segment. Releasing the key equips the selected slot.

local WeaponWheel = {}
local Items = require 'modules.items.client'

-- Slot 0 is the fist segment
local FIST = 0

-- Segment angle per slot (0 = top, clockwise), must match ANGLES in WeaponWheel.tsx
local SLOT_ANGLE = { [1] = 240, [2] = 300, [3] = 0, [4] = 60, [5] = 120, [FIST] = 180 }
local SLOT_ORDER = { 1, 2, 3, 4, 5, FIST }

-- Weapons usable per vehicle seat. GTA reads this from the vehicle layouts and has no native
-- to query it, so it is mirrored here. Adjust if the server uses custom vehicle layouts.
local ONE_HANDED_SMGS = { 'WEAPON_MICROSMG', 'WEAPON_MINISMG', 'WEAPON_MACHINEPISTOL', 'WEAPON_TECPISTOL' }

local VEHICLE_WEAPONS = {
	driver = {
		groups = { `GROUP_PISTOL`, `GROUP_STUNGUN`, `GROUP_THROWN` },
		weapons = ONE_HANDED_SMGS,
	},
	passenger = {
		groups = { `GROUP_PISTOL`, `GROUP_STUNGUN`, `GROUP_THROWN`, `GROUP_SMG`, `GROUP_RIFLE`, `GROUP_SHOTGUN`, `GROUP_MG` },
	},
	bikeDriver = {
		groups = { `GROUP_PISTOL`, `GROUP_STUNGUN`, `GROUP_THROWN`, `GROUP_MELEE` },
		weapons = ONE_HANDED_SMGS,
	},
	bikePassenger = {
		groups = { `GROUP_PISTOL`, `GROUP_STUNGUN`, `GROUP_THROWN`, `GROUP_MELEE`, `GROUP_SMG` },
	},
	-- Helicopter and plane pilots can not use hand weapons
	pilot = {},
}

-- Converts the lists above into lookup sets
for _, rule in pairs(VEHICLE_WEAPONS) do
	local groups, weapons = {}, {}

	for i = 1, #(rule.groups or {}) do groups[rule.groups[i]] = true end
	for i = 1, #(rule.weapons or {}) do weapons[joaat(rule.weapons[i])] = true end

	rule.groups, rule.weapons = groups, weapons
end

-- Mouse delta sensitivity and deadzone of the virtual selection stick
local MOUSE_SENSITIVITY = 1.5
local DEADZONE = 0.35

-- Controls blocked while the wheel is open, movement stays enabled
local BLOCKED_CONTROLS = {
	1, 2, 3, 4, 5, 6,               -- camera look
	12, 13, 14, 15, 16, 17, 37,     -- native weapon wheel and weapon scroll
	24, 25, 257, 263, 264,          -- attack / aim
	140, 141, 142, 143,             -- melee
	45, 80,                         -- reload
	68, 69, 70, 91, 92, 99, 100, 106, 114, 330, 331, -- vehicle weapons and mouse control
	157, 158, 159, 160, 161, 162, 163, 164, 165, -- native weapon select keys
	199, 200, 322,                  -- pause menu (ESC cancels the wheel instead)
}

local isOpen = false
local hovered = FIST

-- Slots that can be selected, the fist always can
local available = { [FIST] = true }

-- Virtual selection stick, fed by mouse deltas
local stickX, stickY = 0.0, 0.0

---@class WeaponWheelContext
---@field canOpen fun(): boolean
---@field shouldClose fun(): boolean?
---@field getCurrentWeapon fun(): table?
---@field useSlot fun(slot: number)
---@field disarm fun()

---@type WeaponWheelContext?
local ctx

---@param context WeaponWheelContext
function WeaponWheel.setup(context)
	ctx = context
end

---@param slot number
---@return boolean
local function isWeaponSlot(slot)
	local item = PlayerData.inventory[slot]
	local data = item and Items[item.name]

	return data and data.weapon and true or false
end

---@return table? rule weapon rule of the current vehicle seat, nil when on foot
local function getVehicleRule()
	local vehicle = cache.vehicle

	if not vehicle then return end

	local class = GetVehicleClass(vehicle)
	local isDriver = cache.seat == -1

	if class == 8 or class == 13 then
		return isDriver and VEHICLE_WEAPONS.bikeDriver or VEHICLE_WEAPONS.bikePassenger
	end

	if isDriver and (class == 15 or class == 16) then
		return VEHICLE_WEAPONS.pilot
	end

	return isDriver and VEHICLE_WEAPONS.driver or VEHICLE_WEAPONS.passenger
end

-- Weapon can not be equipped on the current vehicle seat
---@param slot number
---@param rule table?
---@return boolean
local function isBlockedInVehicle(slot, rule)
	if not rule then return false end

	local data = Items[PlayerData.inventory[slot].name]
	local hash = data.hash

	return not rule.weapons[hash] and not rule.groups[GetWeapontypeGroup(hash)]
end

-- FiveM native, reads the clip size of a clip component from the weapon metadata
local GetWeaponComponentClipSize = GetWeaponComponentClipSize

-- Max rounds the weapon model can hold in one clip, including attached clip components
---@param slot number
---@return number
local function getClipCapacity(slot)
	local item = PlayerData.inventory[slot]
	local data = item and Items[item.name]
	local hash = data?.hash

	if not data or not data.weapon or not data.ammoname or not hash then return 0 end

	-- Equipped weapon: ask the ped directly, covers every component the game applied
	local current = ctx.getCurrentWeapon()

	if current?.slot == slot and current.hash == hash then
		local size = GetMaxAmmoInClip(cache.ped, hash, true)

		if size > 0 then return size end
	end

	local capacity = GetWeaponClipSize(hash)

	if not GetWeaponComponentClipSize then return capacity end

	local metadata = item.metadata or {}
	local components = metadata.components

	if components then
		for i = 1, #components do
			local component = Items[components[i]]
			local hashes = component?.type == 'magazine' and component.client?.component

			if hashes then
				for j = 1, #hashes do
					if DoesWeaponTakeWeaponComponent(hash, hashes[j]) then
						local size = GetWeaponComponentClipSize(hashes[j])

						if size > capacity then capacity = size end
					end
				end
			end
		end
	end

	-- Special ammo swaps the clip component, same naming as in client.lua useSlot
	if type(metadata.specialAmmo) == 'string' and data.model then
		local clipComponent = data.model:gsub('WEAPON_', 'COMPONENT_')
		local specialClip = joaat(('%s_CLIP_%s'):format(clipComponent, metadata.specialAmmo:upper()))

		if DoesWeaponTakeWeaponComponent(hash, specialClip) then
			local size = GetWeaponComponentClipSize(specialClip)

			if size > 0 then capacity = size end
		end
	end

	return capacity
end

-- Nearest selectable segment by angle, ties go clockwise (= next slot number)
---@param deg number
---@return number
local function nearestAvailable(deg)
	local best, bestDist = FIST, math.huge

	for i = 1, #SLOT_ORDER do
		local slot = SLOT_ORDER[i]

		if available[slot] then
			local cw = (SLOT_ANGLE[slot] - deg) % 360
			local dist = math.min(cw, 360 - cw) - (cw <= 180 and 0.001 or 0)

			if dist < bestDist then
				best, bestDist = slot, dist
			end
		end
	end

	return best
end

-- Weapon slots and whether each can be selected right now, index = slot 1-5
---@return boolean[] weapons, boolean[] blocked
local function updateAvailable()
	local rule = getVehicleRule()
	local weapons, blocked = {}, {}

	for slot = 1, 5 do
		weapons[slot] = isWeaponSlot(slot)
		blocked[slot] = weapons[slot] and isBlockedInVehicle(slot, rule)
		available[slot] = weapons[slot] and not blocked[slot]
	end

	return weapons, blocked
end

-- Unavailable targets snap to the nearest available segment
---@param slot number
local function setHover(slot)
	if not available[slot] then slot = nearestAvailable(SLOT_ANGLE[slot]) end
	if slot == hovered then return end

	hovered = slot
	SendNUIMessage({ action = 'weaponWheelHover', data = slot })
end

local function close()
	if not isOpen then return end

	isOpen = false
	SendNUIMessage({ action = 'closeWeaponWheel' })
end

-- Keeps ESC from reaching the pause menu until it is released
local function swallowPause()
	CreateThread(function()
		repeat
			DisableControlAction(0, 199, true)
			DisableControlAction(0, 200, true)
			DisableControlAction(0, 322, true)
			Wait(0)
		until not IsDisabledControlPressed(0, 200) and not IsDisabledControlPressed(0, 322)
	end)
end

---@param slot number
local function equipSlot(slot)
	if not ctx then return end

	if slot == FIST then return ctx.disarm() end

	-- Inventory or seat changed since the wheel updated, keep the current weapon
	if not isWeaponSlot(slot) or isBlockedInVehicle(slot, getVehicleRule()) then return end

	-- Selecting the equipped weapon again keeps it (useSlot would holster it)
	if ctx.getCurrentWeapon()?.slot == slot then return end

	ctx.useSlot(slot)
end

function WeaponWheel.open()
	if isOpen or not ctx or not ctx.canOpen() then return end

	local weapon = ctx.getCurrentWeapon()
	local weapons, blocked = updateAvailable()
	local capacity = {}

	for slot = 1, 5 do
		capacity[slot] = weapons[slot] and getClipCapacity(slot) or 0
	end

	local equipped = weapon?.slot

	isOpen = true
	hovered = equipped and available[equipped] and equipped or nearestAvailable(SLOT_ANGLE[equipped or FIST])
	stickX, stickY = 0.0, 0.0

	SendNUIMessage({
		action = 'openWeaponWheel',
		data = {
			equipped = equipped,
			hovered = hovered,
			weapons = weapons,
			blocked = blocked,
			capacity = capacity,
			-- Live ammo of the equipped weapon, the slot metadata is only synced periodically
			ammo = weapon?.hash and GetAmmoInPedWeapon(cache.ped, weapon.hash) or nil,
		}
	})

	CreateThread(function()
		local playerId = cache.playerId
		local vehicle, seat = cache.vehicle, cache.seat

		while isOpen do
			if ctx.shouldClose() then
				close()
				break
			end

			-- Entering, leaving or switching seats changes which weapons can be used
			if cache.vehicle ~= vehicle or cache.seat ~= seat then
				vehicle, seat = cache.vehicle, cache.seat
				local _, nowBlocked = updateAvailable()

				SendNUIMessage({ action = 'weaponWheelBlocked', data = nowBlocked })

				if not available[hovered] then
					stickX, stickY = 0.0, 0.0
					setHover(hovered)
				end
			end

			for i = 1, #BLOCKED_CONTROLS do
				DisableControlAction(0, BLOCKED_CONTROLS[i], true)
			end

			DisablePlayerFiring(playerId, true)
			HideHudComponentThisFrame(19)
			HideHudComponentThisFrame(20)

			-- Mouse deltas feed a virtual stick, its direction picks the segment
			stickX += GetDisabledControlUnboundNormal(0, 1) * MOUSE_SENSITIVITY
			stickY += GetDisabledControlUnboundNormal(0, 2) * MOUSE_SENSITIVITY

			local length = math.sqrt(stickX * stickX + stickY * stickY)

			if length > 1.0 then
				stickX, stickY = stickX / length, stickY / length
				length = 1.0
			end

			if length >= DEADZONE then
				local deg = math.deg(math.atan(stickX, -stickY)) % 360
				setHover(nearestAvailable(deg))
			end

			-- Key 6 (native "select handgun") picks the fist, keys 1-5 go through the hotkey keybinds
			if IsDisabledControlJustPressed(0, 159) then
				stickX, stickY = 0.0, 0.0
				setHover(FIST)
			end

			if IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 322) then
				close()
				swallowPause()
				break
			end

			Wait(0)
		end
	end)
end

-- Called when the wheel key is released, equips the hovered slot
function WeaponWheel.release()
	if not isOpen then return end

	close()
	equipSlot(hovered)
end

---@param slot number
function WeaponWheel.hover(slot)
	if not isOpen then return end

	-- Key selection wins until the mouse leaves the deadzone again
	stickX, stickY = 0.0, 0.0
	setHover(slot)
end

function WeaponWheel.isOpen()
	return isOpen
end

return WeaponWheel
