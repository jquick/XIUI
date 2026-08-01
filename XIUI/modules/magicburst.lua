--[[
* Magic Burst notification for XIUI
*
* Shows a large elemental image with a countdown for as long as a skillchain's
* magic burst window is open, pulsing harder as the window runs out.
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local skillchain = require('modules.hotbar.skillchain');
local TextureManager = require('libs.texturemanager');
local imtext = require('libs.imtext');
local defaultPositions = require('libs.defaultpositions');

local magicburst = {};

local WINDOW_NAME = 'MagicBurst';

local FADE_IN_SECONDS = 0.2;
local PULSE_SECONDS = 3.0;
local PULSE_HZ = 3.5;
local PULSE_MAX_FADE = 0.55;
local PULSE_MAX_GROW = 0.10;

local PREVIEW_ELEMENTS = {
    'fire', 'ice', 'wind', 'earth', 'lightning', 'water', 'light', 'dark',
};
local PREVIEW_LENGTH = 9.0;

local hidden = false;
local previewEnabled = false;
local previewStart = 0;

-- Reused so the per-frame tint costs no allocation.
local tintRGBA = { 1.0, 1.0, 1.0, 1.0 };

local function GetBurstState()
    if previewEnabled then
        local since = os.clock() - previewStart;
        local index = (math.floor(since / PREVIEW_LENGTH) % #PREVIEW_ELEMENTS) + 1;
        local elapsed = since % PREVIEW_LENGTH;
        return PREVIEW_ELEMENTS[index], PREVIEW_LENGTH - elapsed, PREVIEW_LENGTH;
    end
    return skillchain.GetActiveBurst();
end

-- Fade in on open, then flash progressively harder over the last few seconds.
-- Returns alpha (0-1) and a scale multiplier for the pulse.
local function GetPulse(remaining, total)
    local alpha = 1.0;

    local elapsed = total - remaining;
    if elapsed < FADE_IN_SECONDS then
        alpha = elapsed / FADE_IN_SECONDS;
    end

    if remaining > PULSE_SECONDS then
        return alpha, 1.0;
    end

    local intensity = 1.0 - (remaining / PULSE_SECONDS);
    local wave = (math.sin(os.clock() * PULSE_HZ * math.pi * 2) + 1) * 0.5;

    return alpha * (1.0 - (PULSE_MAX_FADE * intensity * wave)),
        1.0 + (PULSE_MAX_GROW * intensity * wave);
end

magicburst.DrawWindow = function(settings)
    if hidden then
        return;
    end

    local element, remaining, total = GetBurstState();
    if not element or not remaining or remaining <= 0 or not total or total <= 0 then
        return;
    end

    local texture = TextureManager.getFileTexture('magicburst/' .. element);
    local texturePtr = texture and TextureManager.getTexturePtr(texture);
    if not texturePtr then
        return;
    end

    local size = settings.imageSize;
    local alpha, pulseScale = GetPulse(remaining, total);

    imgui.SetNextWindowSize({ -1, -1 }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });

    ApplyWindowPosition(WINDOW_NAME);
    if imgui.Begin(WINDOW_NAME, true, GetBaseWindowFlags(gConfig.lockPositions)) then
        SaveWindowPosition(WINDOW_NAME);

        local originX, originY = imgui.GetCursorScreenPos();
        imgui.Dummy({ size, size });

        local drawList = GetUIDrawList();

        -- Grow from the center so the pulse doesn't shift the window.
        local drawSize = size * pulseScale;
        local inset = (size - drawSize) * 0.5;
        local x, y = originX + inset, originY + inset;

        tintRGBA[4] = alpha;
        drawList:AddImage(
            texturePtr,
            { x, y },
            { x + drawSize, y + drawSize },
            { 0, 0 }, { 1, 1 },
            imgui.GetColorU32(tintRGBA)
        );

        if settings.showTimer then
            imtext.SetConfigFromSettings(settings.font_settings);
            local fontSize = settings.font_settings.font_height;
            local label = string.format('%.1f', remaining);
            local textWidth, textHeight = imtext.Measure(label, fontSize);
            imtext.Draw(
                drawList,
                label,
                originX + ((size - textWidth) * 0.5),
                originY + ((size - textHeight) * 0.5),
                settings.font_settings.font_color,
                fontSize
            );
        end
    end
    imgui.End();

    imgui.PopStyleVar();
end

magicburst.Initialize = function(settings)
    hidden = false;
end

magicburst.UpdateVisuals = function(settings)
end

magicburst.SetHidden = function(isHidden)
    hidden = isHidden == true;
end

magicburst.Cleanup = function()
    hidden = false;
end

-- Config preview: the real window only lasts seconds, so allow forcing it on
-- while positioning and sizing.
magicburst.SetPreview = function(enabled)
    if enabled and not previewEnabled then
        previewStart = os.clock();
    end
    previewEnabled = enabled == true;
end

magicburst.ResetPositions = function()
    local x, y = defaultPositions.GetMagicBurstPosition();
    if gConfig and gConfig.windowPositions then
        gConfig.windowPositions[WINDOW_NAME] = { x = x, y = y };
        if gConfig.appliedPositions then
            gConfig.appliedPositions[WINDOW_NAME] = nil;
        end
    end
end

return magicburst;
