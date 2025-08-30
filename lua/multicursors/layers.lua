local Hydra = require 'hydra'

---@type InsertMode
local insert_mode = require 'multicursors.insert_mode'

---@type NormalMode
local normal_mode = require 'multicursors.normal_mode'

---@type Utils
local utils = require 'multicursors.utils'

---@class Layers
local L = {}

L.normal_hydra = nil

L.insert_hydra = nil

L.extend_hydra = nil

---
---@param keys Dictionary: { [string]: Action }
---@param nowait boolean
---@return Head[]
local set_heads_options = function(keys, nowait)
    ---@type Head[]
    local heads = {}
    for lhs, action in pairs(keys) do
        if action.method ~= false then
            local opts = action.opts or {}

            if action.opts.nowait ~= nil then
                opts.nowait = action.opts.nowait
            else
                opts.nowait = nowait
            end

            heads[#heads + 1] = {
                lhs,
                action.method,
                opts,
            }
        end
    end

    return heads
end

--- Creates a hint for a head
--- when necessary adds padding or cuts the hint for aligning
---@param head Head
---@param max_hint_length integer
---@param hint_separator string
---@return string
local function get_hint(head, max_hint_length, hint_separator)
    if not head[3].desc or head[3].desc == '' then
        return ''
    end

    local key = tostring(head[1] or '')
    local desc = tostring(head[3].desc or '')

    -- Visible (what the user actually sees) vs markup (what we render)
    local left_visible = key .. ' ' .. hint_separator .. ' '
    local left_markup = '_' .. key .. '_ ' .. hint_separator .. ' '

    local caret_width = 1 -- reserve for trailing '^'
    local left_w = vim.fn.strdisplaywidth(left_visible)
    local available = max_hint_length - caret_width - left_w
    if available < 0 then
        available = 0
    end

    local ellipsis = '... '
    local need_ellipsis = vim.fn.strdisplaywidth(desc) > available
    local target_w = need_ellipsis
            and (available - vim.fn.strdisplaywidth(ellipsis))
        or available
    if target_w < 0 then
        target_w = 0
    end

    -- width-aware cut on desc
    local lo, hi = 0, vim.fn.strcharlen(desc)
    local cut = ''
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local part = vim.fn.strcharpart(desc, 0, mid)
        local w = vim.fn.strdisplaywidth(part)
        if w <= target_w then
            cut = part
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    local rendered = left_markup
        .. cut
        .. (need_ellipsis and ellipsis or '')
        .. '^'

    -- pad to exact column width using *visible* width
    local visible_w = left_w
        + vim.fn.strdisplaywidth(cut .. (need_ellipsis and ellipsis or ''))
        + caret_width
    if visible_w < max_hint_length then
        rendered = rendered .. string.rep(' ', max_hint_length - visible_w)
    end

    return rendered
end

local function is_non_special(s)
    return s:match '^[%a%d]+$' ~= nil
end

-- Case-insensitive alpha compare; when equal ignoring case, lowercase wins.
local function alpha_compare(left, right)
    local left_lower, right_lower = left:lower(), right:lower()
    if left_lower ~= right_lower then
        return left_lower < right_lower
    end

    -- Same ignoring case → prefer lowercase at the first case-only difference
    local i, len_left, len_right = 1, #left, #right
    while i <= len_left and i <= len_right do
        local char_left, char_right = left:sub(i, i), right:sub(i, i)
        if
            char_left:lower() == char_right:lower()
            and char_left ~= char_right
        then
            if char_left:match '%l' and char_right:match '%u' then
                return true
            end
            if char_left:match '%u' and char_right:match '%l' then
                return false
            end
        end
        i = i + 1
    end

    return left < right
end

-- Generates hints based on the configuration and input parameters.
---@param config Config configuration.
---@param heads Head[]
---@param mode string indicating the mode.
---@return string hints as a string.
local generate_hints = function(config, heads, mode)
    if config.generate_hints[mode] == false then
        return 'MultiCursor ' .. mode .. ' mode'
    elseif type(config.generate_hints[mode]) == 'string' then
        return config.generate_hints[mode]
    elseif type(config.generate_hints[mode]) == 'function' then
        return config.generate_hints[mode](heads)
    end

    local padding = config.generate_hints.config.padding
    local vertical_padding = padding[1]
    local horizontal_padding = padding[2]

    local str = ''

    local max_hint_length = config.generate_hints.config.max_hint_length
    local col_gap = 1 -- minimal space between columns

    local total_width = vim.api.nvim_get_option_value('columns', {})
        - horizontal_padding * 2
    local columns = config.generate_hints.config.column_count
        or math.max(
            1,
            math.floor((total_width + col_gap) / (max_hint_length + col_gap))
        )

    -- column-based ordering: sort by key length, then:
    --  - non-special (letters/digits) before special
    --  - case-insensitive alphabetical
    --  - if equal ignoring case, lowercase comes before uppercase
    table.sort(heads, function(left, right)
        local key_left = tostring(left[1] or '')
        local key_right = tostring(right[1] or '')

        local width_left = vim.fn.strdisplaywidth(key_left)
        local width_right = vim.fn.strdisplaywidth(key_right)
        if width_left ~= width_right then
            return width_left < width_right
        end

        local leftIsNonSpecial = is_non_special(key_left)
        local rightIsNonSpecial = is_non_special(key_right)
        if leftIsNonSpecial ~= rightIsNonSpecial then
            return leftIsNonSpecial -- non-special before special
        end

        return alpha_compare(key_left, key_right)
    end)

    local rows = math.max(1, math.ceil(#heads / columns))
    local hint_separator = config.generate_hints.config.hint_separator

    local line
    for i = 0, rows - 1 do
        line = ''
        for j = 1, columns, 1 do
            local idx = ((j - 1) * rows) + (i + 1) -- column-major index
            local h = heads[idx]
            if h then
                line = line .. get_hint(h, max_hint_length, hint_separator)

                -- add gap only if there is another visible cell to the right in this row
                local has_next = false
                for k = j + 1, columns do
                    local idx2 = ((k - 1) * rows) + (i + 1)
                    if heads[idx2] then
                        has_next = true
                        break
                    end
                end
                if has_next then
                    line = line .. string.rep(' ', col_gap)
                end
            end
        end

        if line ~= '' then
            local padding_line = string.rep(' ', horizontal_padding)
            local padded_line = padding_line .. line .. padding_line

            if str == '' then
                str = padded_line
            else
                str = str .. '\n' .. padded_line
            end
        end
    end

    if vertical_padding > 0 and str ~= '' then
        local top_padding = string.rep('\n', vertical_padding)
        local bottom_padding = top_padding .. '\n'
        str = top_padding .. str .. bottom_padding
    end

    return str
end

--- Creates hint configuration for a given mode
---@param config Config
---@param mode string
---@return table
local create_hint_config = function(config, mode)
    local default_config = {
        float_opts = {
            title = ' MC ' .. mode .. ' ',
            title_pos = 'center',
        },
    }
    return vim.tbl_deep_extend('keep', config.hint_config or {}, default_config)
end

---
---@param config Config
---@return Head[]
L.generate_normal_heads = function(config)
    local heads = set_heads_options(config.normal_keys, config.nowait)
    local enter_insert = function(callback)
        -- tell hydra that we're going to insert mode so it doesn't clear the selection
        vim.b.MultiCursorSubLayer = true

        callback()
        L.create_insert_hydra(config)
        L.insert_hydra:activate()
    end

    heads[#heads + 1] = {
        '<Esc>',
        nil,
        { desc = 'exit', exit = true, nowait = config.nowait },
    }

    heads[#heads + 1] = {
        config.mode_keys.insert,
        function()
            enter_insert(function()
                insert_mode.insert(config)
            end)
        end,
        { desc = 'insert mode', exit = true, nowait = config.nowait },
    }

    heads[#heads + 1] = {
        config.mode_keys.change,
        function()
            enter_insert(function()
                normal_mode.change(config)
            end)
        end,
        { desc = 'change mode', exit = true, nowait = config.nowait },
    }

    heads[#heads + 1] = {
        config.mode_keys.append,
        function()
            enter_insert(function()
                insert_mode.append(config)
            end)
        end,
        { desc = 'append mode', exit = true, nowait = config.nowait },
    }

    heads[#heads + 1] = {
        config.mode_keys.extend,
        function()
            vim.b.MultiCursorSubLayer = true
            L.create_extend_hydra(config)
            L.extend_hydra:activate()
        end,
        { desc = 'extend mode', exit = true, nowait = config.nowait },
    }

    return heads
end

---
---@param config Config
L.create_normal_hydra = function(config)
    local heads = L.generate_normal_heads(config)

    L.normal_hydra = Hydra {
        name = 'MC Normal',
        hint = generate_hints(config, heads, 'normal'),
        config = {
            buffer = 0,
            on_enter = function()
                vim.b.MultiCursorAnchorStart = true
            end,
            on_exit = function()
                if not vim.b.MultiCursorSubLayer then
                    utils.exit()
                end
            end,
            color = 'pink',
            hint = create_hint_config(config, 'Normal'),
        },
        mode = 'n',
        heads = heads,
    }
end

---@param config Config
---@return Head[]
L.generate_insert_heads = function(config)
    return set_heads_options(config.insert_keys, config.nowait)
end

---@param config Config
L.create_insert_hydra = function(config)
    local heads = L.generate_insert_heads(config)
    L.insert_hydra = Hydra {
        name = 'MC Insert',
        hint = generate_hints(config, heads, 'insert'),
        mode = 'i',
        config = {
            buffer = 0,
            on_enter = function() end,
            on_exit = function()
                vim.defer_fn(function()
                    insert_mode.exit()
                    L.normal_hydra:activate()
                end, 20)
            end,
            color = 'pink',
            hint = create_hint_config(config, 'Insert'),
        },
        heads = heads,
    }
end

---@param config Config
---@return Head[]
L.generate_extend_heads = function(config)
    return set_heads_options(config.extend_keys, config.nowait)
end

---@param config Config
L.create_extend_hydra = function(config)
    local heads = L.generate_extend_heads(config)

    L.extend_hydra = Hydra {
        name = 'MC Extend',
        hint = generate_hints(config, heads, 'extend'),
        mode = 'n',
        config = {
            buffer = 0,
            on_enter = function()
                vim.cmd.redraw()
            end,
            on_exit = function()
                vim.b.MultiCursorSubLayer = nil
                vim.defer_fn(function()
                    L.normal_hydra:activate()
                end, 20)
            end,
            color = 'pink',
            hint = create_hint_config(config, 'Extend'),
        },
        heads = heads,
    }
end

return L
