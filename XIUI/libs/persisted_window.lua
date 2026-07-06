--[[
* Persisted ImGui window position helpers.
*
* Used by windows that store geometry in gConfig.windowPositions and must seed
* pos+size before Begin (AlwaysAutoResize windows stretch if repositioned inside Begin).
]]--

local imgui = require('imgui');

local M = {};

M.RECOVER_ORIGIN = { 20, 20 };

local pendingRecover = {};

local function getSaved(positionKey)
    return gConfig and gConfig.windowPositions and gConfig.windowPositions[positionKey];
end

local function clearApplied(positionKey)
    if gConfig and gConfig.appliedPositions then
        gConfig.appliedPositions[positionKey] = nil;
    end
end

-- Call before imgui.Begin. Returns true when saved geometry will be applied this frame.
function M.PrepareOpen(positionKey, options)
    options = options or {};
    local seedSize = options.seedSize or { 200, 100 };

    if options.centerNext or pendingRecover[positionKey] then
        clearApplied(positionKey);
        pendingRecover[positionKey] = nil;
    end

    local saved = getSaved(positionKey);
    local applied = gConfig and gConfig.appliedPositions;
    local shouldApply = saved and (not applied or not applied[positionKey]);

    if shouldApply then
        imgui.SetNextWindowPos({ saved.x, saved.y }, ImGuiCond_Always);
        imgui.SetNextWindowSize({
            saved.w or seedSize[1],
            saved.h or seedSize[2],
        }, ImGuiCond_Always);
    elseif options.centerNext and not saved and options.centerPos then
        imgui.SetNextWindowPos(options.centerPos, ImGuiCond_Appearing, options.centerPivot or { 0, 0 });
    elseif options.defaultSize then
        imgui.SetNextWindowSize(options.defaultSize, ImGuiCond_FirstUseEver);
    end

    return shouldApply;
end

-- Call as the first line inside imgui.Begin.
function M.FinishOpen(positionKey, shouldApply)
    if shouldApply then
        if not gConfig.appliedPositions then
            gConfig.appliedPositions = {};
        end
        gConfig.appliedPositions[positionKey] = true;
    else
        M.SaveGeometry(positionKey);
    end
end

function M.SaveGeometry(positionKey)
    if not gConfig then return; end

    local x, y = imgui.GetWindowPos();
    local w, h = imgui.GetWindowSize();
    if not gConfig.windowPositions then
        gConfig.windowPositions = {};
    end

    local saved = gConfig.windowPositions[positionKey];
    if not saved then
        gConfig.windowPositions[positionKey] = { x = x, y = y, w = w, h = h };
    else
        saved.x = x;
        saved.y = y;
        saved.w = w;
        saved.h = h;
    end
end

function M.RequestRecover(positionKey, origin)
    if not gConfig then return; end
    if not gConfig.windowPositions then
        gConfig.windowPositions = {};
    end

    origin = origin or M.RECOVER_ORIGIN;
    gConfig.windowPositions[positionKey] = { x = origin[1], y = origin[2] };
    clearApplied(positionKey);
    pendingRecover[positionKey] = true;
end

return M;
