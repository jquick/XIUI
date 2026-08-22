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
local doubleUp = nil;
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

local function ArmTimer(entry, duration)
    local now = os.clock();
    entry.expiresAt = now + duration;
    entry.duration = duration;
    entry.pending = true;
end

-- Packet is after animation; adopt a readable status timer once, then coast.
local function SnapTimer(entry, seconds, now)
    if entry == nil or not entry.pending then return; end
    if seconds == nil or seconds < 0 then return; end
    entry.expiresAt = now + seconds;
    if seconds > 0 then
        entry.duration = math.max(entry.duration or seconds, seconds);
    end
    entry.pending = false;
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

-- Reuse this roll, else an empty seat, else the live roll that expires first.
-- Never evicts a bust (Hunter replacing Chaos must leave a busted seat).
local function ClaimSlot(statusId)
    local empty, oldest, shortest = nil, nil, math.huge;
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry == nil then
            empty = empty or i;
        elseif not entry.busted then
            if entry.status == statusId then return i; end
            local left = Remaining(entry.expiresAt);
            if left < shortest then
                oldest, shortest = i, left;
            end
        end
    end
    return empty or oldest;
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
    local reuse = entry ~= nil and entry.status == def.status;
    if not reuse then
        entry = { ability = def.ability, status = def.status, sequence = 0 };
        slots[index] = entry;
    end
    -- This server resets roll duration on Double-Up as well as a new roll.
    ArmTimer(entry, data.BASE_DURATION);

    rollSequence = rollSequence + 1;
    entry.total = total;
    entry.sequence = rollSequence;
    entry.busted = total > data.MAX_TOTAL;
    entry.context = data.Context(HorizonMode());
    if entry.busted then
        doubleUp = nil;
    elseif not reuse then
        doubleUp = {};
        ArmTimer(doubleUp, data.DOUBLE_UP_DURATION);
    end
    lastSyncAt = 0;
end

M.DoubleUp = function()
    local seconds = Remaining(doubleUp and doubleUp.expiresAt);
    if seconds <= 0 then return nil, 0; end

    local best = nil;
    for i = 1, MAX_SLOTS do
        local entry = slots[i];
        if entry ~= nil and (best == nil or entry.sequence > slots[best].sequence) then
            best = i;
        end
    end
    if best == nil or slots[best].busted then return nil, seconds; end
    return best, seconds;
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
                if bustSeen > bustTimesN then
                    if not entry.pending then slots[i] = nil; end
                else
                    SnapTimer(entry, bustTimesBuf[bustSeen], now);
                end
            elseif not presentBuf[entry.status] then
                if not entry.pending then slots[i] = nil; end
            else
                SnapTimer(entry, timersBuf[entry.status], now);
            end
        end
    end

    -- Leftover 309s with no packet seat go in empty slots.
    for i = 1, MAX_SLOTS do
        if slots[i] == nil and bustSeen < bustTimesN then
            bustSeen = bustSeen + 1;
            local seconds = bustTimesBuf[bustSeen] or 0;
            slots[i] = {
                status = data.BUST_STATUS,
                total = data.BUST_TOTAL,
                sequence = 0,
                busted = true,
                pending = false,
                expiresAt = now + seconds,
                duration = math.max(seconds, 1),
            };
        end
    end

    if doubleUp == nil then return; end

    if presentBuf[data.DOUBLE_UP_STATUS] then
        SnapTimer(doubleUp, timersBuf[data.DOUBLE_UP_STATUS], now);
    elseif not doubleUp.pending then
        doubleUp = nil;
    end
end

M.SecondsLeft = function(entry)
    if entry == nil or entry.expiresAt == nil then return nil; end
    return Remaining(entry.expiresAt);
end

M.Slots = function()
    return slots;
end

M.HasAny = function()
    return slots[1] ~= nil or slots[2] ~= nil;
end

M.Clear = function()
    slots = {};
    rollSequence = 0;
    doubleUp = nil;
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
    doubleUp = { expiresAt = now + 32, duration = data.DOUBLE_UP_DURATION };
end

return M;
