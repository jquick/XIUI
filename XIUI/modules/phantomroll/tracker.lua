--[[
* Tracks the two Phantom Rolls a Corsair can keep. Packets own totals; buff
* timers own the countdown. Other Corsairs' rolls share status ids — ignore them.
]]--

local data = require('modules.phantomroll.data');
local vanatime = require('libs.vanatime');

local M = {};

local MAX_SLOTS = 2;
-- Bars interpolate from expiresAt; poll buffs a few times a second to refresh/clear.
local SYNC_INTERVAL = 0.15;

local slots = {};
local rollSequence = 0;
local doubleUpExpiresAt = nil;
local lastSyncAt = 0;

-- Reused across Sync calls so we do not allocate every frame.
local presentBuf, timersBuf = {}, {};

local function Now()
    return os.clock();
end

local function Left(expiresAt)
    if expiresAt == nil then return 0; end
    return math.max(0, expiresAt - Now());
end

local function ClearMap(map)
    for key in pairs(map) do map[key] = nil; end
end

local function HorizonMode()
    local settings = gAdjustedSettings and gAdjustedSettings.phantomRollSettings;
    return settings ~= nil and settings.horizonMode == true;
end

-- Seed a packet-time countdown; Sync replaces it once the buff is readable.
local function ArmCountdown(entry)
    local now = Now();
    entry.expiresAt = now + data.BASE_DURATION;
    entry.duration = data.BASE_DURATION;
    entry.pending = true;  -- do not clear until the buff has been seen once
end

-- Split presence from readable timers so an unreadable stamp is not "missing".
local function ReadRollBuffs()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil then return nil, nil; end

    local buffs = player:GetBuffs();
    if buffs == nil then return nil, nil; end
    local statusTimers = player:GetStatusTimers();
    local stamp = vanatime.Utc();

    ClearMap(presentBuf);
    ClearMap(timersBuf);

    for i = 1, 32 do
        local statusId = buffs[i];
        if statusId ~= nil and data.IsTrackedStatus(statusId) then
            presentBuf[statusId] = true;
            local seconds = vanatime.StatusSeconds(statusTimers and statusTimers[i] or nil, stamp);
            if seconds ~= nil then
                timersBuf[statusId] = seconds;
            end
        end
    end
    return presentBuf, timersBuf;
end

local function FindSlot(statusId)
    for i = 1, MAX_SLOTS do
        if slots[i] ~= nil and slots[i].status == statusId then return i; end
    end
    return nil;
end

local function NewEntry(def, total)
    local entry = {
        ability = def.ability,
        status = def.status,
        total = total,
        sequence = 0,  -- 0: never saw this roll, so it cannot be doubled up
        busted = false,
    };
    ArmCountdown(entry);
    return entry;
end

-- Free seat, else soonest-expiring non-bust (what the server drops at two rolls).
local function ReplacementSlot()
    for i = 1, MAX_SLOTS do
        if slots[i] == nil then return i; end
    end

    local victim, shortest = nil, math.huge;
    for i = 1, MAX_SLOTS do
        local remaining = M.SecondsLeft(slots[i]) or 0;
        if not slots[i].busted and remaining < shortest then
            victim, shortest = i, remaining;
        end
    end
    return victim or 1;
end

local function Place(def, total)
    local index = FindSlot(def.status);
    if index ~= nil then
        return index, slots[index];
    end

    index = ReplacementSlot();
    local entry = NewEntry(def, total);
    slots[index] = entry;
    return index, entry;
end

-- Keep the same seat/identity; only the countdown switches to the Bust debuff.
local function MarkBusted(index, entry)
    for i = 1, MAX_SLOTS do
        if i ~= index and slots[i] ~= nil and slots[i].busted then slots[i] = nil; end
    end

    entry.busted = true;
    ArmCountdown(entry);
end

local function RollTotal(actionPacket, serverId)
    if actionPacket.Targets == nil then return nil; end

    local fallback = nil;
    for _, target in ipairs(actionPacket.Targets) do
        local action = target.Actions and target.Actions[1];
        if action ~= nil then
            if target.Id == serverId then return action.Param; end
            fallback = fallback or action.Param;
        end
    end
    return fallback;
end

local function ApplyTimer(entry, seconds, now)
    if seconds == nil or seconds < 0 then return; end
    entry.expiresAt = now + seconds;
    entry.duration = math.max(entry.duration or seconds, seconds);
end

M.HandleActionPacket = function(actionPacket)
    if actionPacket == nil or actionPacket.Type ~= data.JOB_ABILITY_CATEGORY then return; end

    local def = data.ByAbility(actionPacket.Param);
    if def == nil then return; end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local serverId = party and party:GetMemberServerId(0);
    if serverId == nil or actionPacket.UserId ~= serverId then return; end

    local total = RollTotal(actionPacket, serverId);
    if total == nil then return; end

    local index, entry = Place(def, total);

    rollSequence = rollSequence + 1;
    entry.sequence = rollSequence;
    entry.total = total;

    if total > data.MAX_TOTAL then
        MarkBusted(index, entry);
        doubleUpExpiresAt = nil;
    else
        entry.busted = false;
        ArmCountdown(entry);
    end

    -- Potency is fixed when the roll lands; snapshot gear/party/level here.
    entry.context = data.Context(HorizonMode());
    lastSyncAt = 0;  -- pick the new buff up on the next draw
end

M.DoubleUpIndex = function()
    if Left(doubleUpExpiresAt) <= 0 then return nil; end

    local best, bestSequence = nil, 0;
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil and entry.sequence > bestSequence then
            best, bestSequence = i, entry.sequence;
        end
    end

    if best ~= nil and slots[best].busted then return nil; end
    return best;
end

M.DoubleUpSeconds = function()
    return Left(doubleUpExpiresAt);
end

M.Sync = function()
    local now = Now();
    if (now - lastSyncAt) < SYNC_INTERVAL then return; end
    lastSyncAt = now;

    local present, timers = ReadRollBuffs();
    if present == nil then return; end

    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil then
            local timerId = entry.busted and data.BUST_STATUS or entry.status;
            if not present[timerId] then
                -- Bust swap: outgoing roll buff can linger; that is still this seat.
                local swapping = entry.busted and present[entry.status];
                if not swapping and not entry.pending then
                    slots[i] = nil;
                end
            else
                entry.pending = false;
                ApplyTimer(entry, timers[timerId], now);
            end
        end
    end

    if not present[data.DOUBLE_UP_STATUS] then
        doubleUpExpiresAt = nil;
    else
        local seconds = timers[data.DOUBLE_UP_STATUS];
        if seconds ~= nil and seconds >= 0 then
            doubleUpExpiresAt = now + seconds;
        end
    end
end

M.SecondsLeft = function(entry)
    if entry == nil or entry.expiresAt == nil then return nil; end
    return Left(entry.expiresAt);
end

M.Fraction = function(entry)
    local remaining = M.SecondsLeft(entry);
    if remaining == nil then return 0; end

    local duration = entry.duration;
    if duration == nil or duration <= 0 then duration = data.BASE_DURATION; end

    return math.min(1, math.max(0, remaining / duration));
end

M.Slots = function()
    return slots, MAX_SLOTS;
end

M.HasAny = function()
    for i = 1, MAX_SLOTS do
        if slots[i] ~= nil then return true; end
    end
    return false;
end

M.Clear = function()
    slots = {};
    rollSequence = 0;
    doubleUpExpiresAt = nil;
    lastSyncAt = 0;
end

M.Demo = function()
    local hunters = data.ByAbility(108);
    local chaos = data.ByAbility(105);
    local now = Now();
    local context = data.Context(false);

    slots = {};
    slots[1] = NewEntry(hunters, hunters.lucky);
    slots[1].expiresAt, slots[1].duration, slots[1].sequence = now + 268, 300, 1;
    slots[1].pending = false;
    slots[1].context = context;

    -- Lucky + unlucky pair; right die rolled last so it shows bust odds.
    slots[2] = NewEntry(chaos, chaos.unlucky);
    slots[2].expiresAt, slots[2].duration, slots[2].sequence = now + 154, 300, 2;
    slots[2].pending = false;
    slots[2].context = context;

    rollSequence = 2;
    doubleUpExpiresAt = now + 32;
end

return M;
