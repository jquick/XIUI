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

-- Reused across Sync calls so we do not allocate every poll.
local presentBuf, timersBuf, bustTimesBuf = {}, {}, {};
local bustTimesN = 0;

local function Remaining(expiresAt)
    if expiresAt == nil then return 0; end
    return math.max(0, expiresAt - os.clock());
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
    local now = os.clock();
    entry.expiresAt = now + data.BASE_DURATION;
    entry.duration = data.BASE_DURATION;
    entry.pending = true;
end

local function ApplyTimer(entry, seconds, now)
    if seconds == nil or seconds < 0 then return; end
    entry.expiresAt = now + seconds;
    entry.duration = math.max(entry.duration or seconds, seconds);
end

-- Split presence from readable timers so an unreadable stamp is not "missing".
local function ReadRollBuffs()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil then return false; end

    local buffs = player:GetBuffs();
    if buffs == nil then return false; end
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
    return true;
end

-- Matching live roll, else a free seat, else the soonest-expiring live roll.
-- Never evicts a bust (Hunter replacing Chaos must leave a busted seat).
local function ClaimSlot(statusId)
    local empty, victim, shortest = nil, nil, math.huge;
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry == nil then
            empty = empty or i;
        elseif not entry.busted and entry.status == statusId then
            return i;
        elseif not entry.busted then
            local left = Remaining(entry.expiresAt);
            if left < shortest then
                victim, shortest = i, left;
            end
        end
    end
    return empty or victim;
end

local function EmptySlot()
    for i = 1, MAX_SLOTS do
        if slots[i] == nil then return i; end
    end
    return nil;
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

M.HandleActionPacket = function(actionPacket)
    if actionPacket == nil or actionPacket.Type ~= data.JOB_ABILITY_CATEGORY then return; end

    local def = data.ByAbility(actionPacket.Param);
    if def == nil then return; end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local serverId = party and party:GetMemberServerId(0);
    if serverId == nil or actionPacket.UserId ~= serverId then return; end

    local total = RollTotal(actionPacket, serverId);
    if total == nil then return; end

    local index = ClaimSlot(def.status);
    if index == nil then return; end

    local entry = slots[index];
    if entry == nil or entry.busted or entry.status ~= def.status then
        entry = { ability = def.ability, status = def.status, sequence = 0 };
        slots[index] = entry;
    end

    rollSequence = rollSequence + 1;
    entry.total = total;
    entry.sequence = rollSequence;
    entry.busted = total > data.MAX_TOTAL;
    entry.context = data.Context(HorizonMode());
    ArmCountdown(entry);
    if entry.busted then doubleUpExpiresAt = nil; end
    lastSyncAt = 0;
end

M.DoubleUpIndex = function()
    if Remaining(doubleUpExpiresAt) <= 0 then return nil; end

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
    return Remaining(doubleUpExpiresAt);
end

M.Sync = function()
    local now = os.clock();
    if (now - lastSyncAt) < SYNC_INTERVAL then return; end
    lastSyncAt = now;
    if not ReadRollBuffs() then return; end

    local bustSeen = 0;
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil then
            if entry.busted then
                bustSeen = bustSeen + 1;
                if bustSeen > bustTimesN and not entry.pending then
                    slots[i] = nil;
                else
                    if bustTimesN > 0 then entry.pending = false; end
                    ApplyTimer(entry, bustTimesBuf[bustSeen], now);
                end
            elseif not presentBuf[entry.status] then
                if not entry.pending then slots[i] = nil; end
            else
                entry.pending = false;
                ApplyTimer(entry, timersBuf[entry.status], now);
            end
        end
    end

    -- Extra 309s with no packet seat (e.g. bust before we saw the roll).
    for n = bustSeen + 1, bustTimesN do
        local seat = EmptySlot();
        if seat == nil then break; end
        local entry = {
            status = data.BUST_STATUS,
            total = data.BUST_TOTAL,
            sequence = 0,
            busted = true,
            pending = false,
        };
        ApplyTimer(entry, bustTimesBuf[n], now);
        slots[seat] = entry;
    end

    if not presentBuf[data.DOUBLE_UP_STATUS] then
        doubleUpExpiresAt = nil;
        return;
    end

    local seconds = timersBuf[data.DOUBLE_UP_STATUS];
    if seconds ~= nil and seconds >= 0 then
        doubleUpExpiresAt = now + seconds;
    end
end

M.SecondsLeft = function(entry)
    if entry == nil or entry.expiresAt == nil then return nil; end
    return Remaining(entry.expiresAt);
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
    return slots[1] ~= nil or slots[2] ~= nil;
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
    local now = os.clock();
    local context = data.Context(HorizonMode());

    local function DemoSeat(def, total, left, sequence)
        return {
            ability = def.ability,
            status = def.status,
            total = total,
            sequence = sequence,
            busted = false,
            pending = false,
            expiresAt = now + left,
            duration = data.BASE_DURATION,
            context = context,
        };
    end

    slots = {
        DemoSeat(hunters, hunters.lucky, 268, 1),
        DemoSeat(chaos, chaos.unlucky, 154, 2),
    };
    rollSequence = 2;
    doubleUpExpiresAt = now + 32;
end

return M;
