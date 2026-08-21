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
local bustTimesBuf = {};
local bustTimesN = 0;

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
    bustTimesN = 0;

    -- 0..32 covers both 0-based and 1-based Ashita buff arrays.
    -- Bust can occupy two slots (same status id); collect every copy.
    for i = 0, 32 do
        local statusId = buffs[i];
        if statusId ~= nil and data.IsTrackedStatus(statusId) then
            local seconds = vanatime.StatusSeconds(statusTimers and statusTimers[i] or nil, stamp);
            if statusId == data.BUST_STATUS then
                bustTimesN = bustTimesN + 1;
                bustTimesBuf[bustTimesN] = seconds;
            else
                presentBuf[statusId] = true;
                if seconds ~= nil then timersBuf[statusId] = seconds; end
            end
        end
    end
    return presentBuf, timersBuf;
end

-- Live rolls only; a busted seat keeps the old status id and must not be reused.
local function FindSlot(statusId)
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil and not entry.busted and entry.status == statusId then
            return i;
        end
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

-- Free seat, else soonest-expiring live roll. Never evicts a bust.
local function ReplacementSlot()
    for i = 1, MAX_SLOTS do
        if slots[i] == nil then return i; end
    end

    local victim, shortest = nil, math.huge;
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil and not entry.busted then
            local remaining = M.SecondsLeft(entry) or 0;
            if remaining < shortest then
                victim, shortest = i, remaining;
            end
        end
    end
    return victim;
end

local function Place(def, total)
    local index = FindSlot(def.status);
    if index ~= nil then
        return index, slots[index];
    end

    index = ReplacementSlot();
    if index == nil then return nil, nil; end

    local entry = NewEntry(def, total);
    slots[index] = entry;
    return index, entry;
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
    if entry == nil then return; end

    rollSequence = rollSequence + 1;
    entry.sequence = rollSequence;
    entry.total = total;

    if total > data.MAX_TOTAL then
        entry.busted = true;
        ArmCountdown(entry);
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

-- Bust dice follow copies of status 309 (you can have two).
local function SyncBusts(now)
    local seen = 0;
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil and entry.busted then
            seen = seen + 1;
            if seen > bustTimesN and not entry.pending then
                slots[i] = nil;
            else
                if bustTimesN > 0 then entry.pending = false; end
                ApplyTimer(entry, bustTimesBuf[seen], now);
            end
        end
    end

    for i = seen + 1, bustTimesN do
        local seat = nil;
        for s = 1, MAX_SLOTS do
            if slots[s] == nil then seat = s; break; end
        end
        if seat == nil then break; end
        slots[seat] = {
            ability = nil,
            status = data.BUST_STATUS,
            total = data.BUST_TOTAL,
            sequence = 0,
            busted = true,
            pending = false,
        };
        ApplyTimer(slots[seat], bustTimesBuf[i], now);
    end
end

M.Sync = function()
    local now = Now();
    if (now - lastSyncAt) < SYNC_INTERVAL then return; end
    lastSyncAt = now;

    local present, timers = ReadRollBuffs();
    if present == nil then return; end

    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil and not entry.busted then
            if not present[entry.status] then
                if not entry.pending then slots[i] = nil; end
            else
                entry.pending = false;
                ApplyTimer(entry, timers[entry.status], now);
            end
        end
    end

    SyncBusts(now);

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
    local context = data.Context(HorizonMode());

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
