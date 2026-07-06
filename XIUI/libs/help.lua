--[[
* XIUI Command Help
*
* Renders a small ImGui window listing XIUI's slash commands. The list is built
* by scanning every .lua file under the addon (vendored submodules excluded) for
* opt-in markers, so it stays in sync automatically. Mark a command, anywhere,
* with a line whose first non-space content is:
*
*     --@cmd <usage> : <description>     (description optional)
*
* Omit the marker to keep a command (e.g. internal/debug ones) hidden.
]]--

local imgui = require('imgui');
local components = require('config.components');
local persistedWindow = require('libs.persisted_window');

local M = {};

local COLOR_CMD  = components.TAB_STYLE.gold;
local COLOR_DESC = { 0.62, 0.64, 0.68, 1.0 };

local isOpen = { false };
local commands = {};

local POSITION_KEY = 'XIUI_Commands';
local WINDOW_ID    = 'XIUI Commands##xiuiHelp';
local SEED_SIZE    = { 440, 480 };

local function scan_file(path, list)
    local f = io.open(path, 'r');
    if not f then return; end
    for line in f:lines() do
        local marker = line:match('^%s*%-%-@cmd%s+(.+)$');
        if marker then
            local usage, desc = marker:match('^(.-)%s*:%s*(.+)$');
            list[#list + 1] = { usage = usage or marker, desc = desc or '' };
        end
    end
    f:close();
end

local function scan_dir(dir, list)
    for _, name in ipairs(ashita.fs.get_directory(dir, '.*') or {}) do
        if name:match('%.lua$') then
            scan_file(dir .. name, list);
        elseif name ~= 'submodules' and not name:match('%.') then
            scan_dir(dir .. name .. '\\', list);
        end
    end
end

local function isRecoverCommand(usage)
    return usage:sub(1, 13) == '/xiui recover';
end

local function collect()
    local list = {};
    scan_dir(string.format('%saddons\\XIUI\\', AshitaCore:GetInstallPath()), list);
    table.sort(list, function(a, b)
        local aRecover = isRecoverCommand(a.usage);
        local bRecover = isRecoverCommand(b.usage);
        if aRecover ~= bRecover then
            return aRecover;
        end
        if aRecover then
            local aEnable = a.usage:find(' enable', 1, true) ~= nil;
            local bEnable = b.usage:find(' enable', 1, true) ~= nil;
            if aEnable ~= bEnable then
                return aEnable;
            end
        end
        return a.usage < b.usage;
    end);
    return list;
end

function M.IsOpen()
    return isOpen[1];
end

function M.Toggle()
    isOpen[1] = not isOpen[1];
    if isOpen[1] then
        commands = collect();
    end
end

function M.RecoverWindowPosition()
    persistedWindow.RequestRecover(POSITION_KEY);
end

function M.Draw()
    if not isOpen[1] then return; end

    local shouldApply = persistedWindow.PrepareOpen(POSITION_KEY, {
        seedSize = SEED_SIZE,
        defaultSize = SEED_SIZE,
    });

    components.PushWindowStyle();
    if imgui.Begin(WINDOW_ID, isOpen, ImGuiWindowFlags_None) then
        persistedWindow.FinishOpen(POSITION_KEY, shouldApply);
        imgui.TextDisabled(string.format('%d commands', #commands));
        imgui.Separator();
        imgui.Spacing();

        for _, entry in ipairs(commands) do
            imgui.TextColored(COLOR_CMD, entry.usage);
            if entry.desc ~= '' then
                imgui.Indent(16);
                imgui.TextColored(COLOR_DESC, entry.desc);
                imgui.Unindent(16);
            end
            imgui.Spacing();
        end
    end
    imgui.End();
    components.PopWindowStyle();
end

return M;
