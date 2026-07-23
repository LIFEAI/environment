local wezterm = require 'wezterm'

local config = wezterm.config_builder()
local act = wezterm.action

local repo = os.getenv 'REGEN_ROOT'
if not repo then
  wezterm.log_error('FATAL: REGEN_ROOT environment variable is not set. Set it to your monorepo root.')
  repo = 'C:\\Dev\\regen-root'
end
local ccandme = 'C:\\Dev\\CCandMe'
local appdata = os.getenv 'APPDATA' or 'C:\\Users\\DaveLadouceur\\AppData\\Roaming'
local code = 'C:\\Users\\DaveLadouceur\\AppData\\Local\\Programs\\Microsoft VS Code\\Code.exe'
local edit_send = 'C:\\Users\\DaveLadouceur\\.codex\\tools\\wezterm-edit-send.ps1'
local agent_session = repo .. '\\scripts\\start-agent-session.ps1'

local function pwsh_cell(role)
  return {
    'pwsh.exe',
    '-NoLogo',
    '-NoExit',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    repo .. '\\scripts\\cell-init.ps1',
    role,
  }
end

local function cmd_keep(command)
  return { 'cmd.exe', '/k', command }
end

config.default_cwd = repo
config.default_prog = { 'pwsh.exe', '-NoLogo' }
config.window_close_confirmation = 'NeverPrompt'
config.audible_bell = 'Disabled'
config.scrollback_lines = 10000
-- Rendering: WebGpu drives the GPU through Direct3D 12 / Vulkan (the wgpu
-- backend), a different code path from the AMD OpenGL driver (atio6axx.dll
-- 31.0.12002.92) that crashed this process on 2026-05-28. The OpenGL stack
-- stays untouched, so we get GPU-accelerated rendering off the GUI thread
-- without re-triggering that crash. The software renderer pinned the single
-- GUI thread doing CPU rasterization, which queued keystrokes behind frame
-- rendering under heavy multi-pane agent output (2026-06-01).
config.front_end = 'WebGpu'
-- Keep terminal rendering cheap under memory pressure. Smooth spinners are not
-- worth input stalls when multiple agent panes are repainting constantly.
config.max_fps = 20
config.animation_fps = 4
config.cursor_blink_ease_in = 'Constant'
config.cursor_blink_ease_out = 'Constant'
config.text_blink_ease_in = 'Constant'
config.text_blink_ease_out = 'Constant'
config.initial_rows = 40
config.window_padding = { left = 12, right = 12, top = 8, bottom = 8 }
config.font = wezterm.font 'Cascadia Code'
config.font_size = 12.5
config.line_height = 1.12
config.cell_width = 1.0
config.default_cursor_style = 'SteadyBar'
config.use_fancy_tab_bar = false
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.show_new_tab_button_in_tab_bar = true
config.tab_max_width = 32
config.switch_to_last_active_tab_when_closing_tab = true
config.selection_word_boundary = ' /\\()"\'-.,:;<>~!@#$%^&*|+=[]{}~?│'
config.bypass_mouse_reporting_modifiers = 'SHIFT'
config.disable_default_key_bindings = false

config.color_scheme = 'Umber Grey'
config.color_schemes = {
  ['Umber Grey'] = {
    foreground = '#D8D2C8',
    background = '#151413',
    cursor_bg = '#B7A98F',
    cursor_fg = '#151413',
    cursor_border = '#B7A98F',
    selection_bg = '#3A3631',
    selection_fg = '#F0E8DC',
    ansi = { '#191816', '#B66A60', '#86A36F', '#C2A56D', '#7F94A8', '#A98BA8', '#7FA39A', '#D8D2C8' },
    brights = { '#5A534A', '#D08378', '#A0BF86', '#D6BA82', '#99AFC4', '#C2A3C0', '#98BDB4', '#F4EEE5' },
  },
  ['Dimidium'] = {
    foreground = '#F8F8F2',
    background = '#282A36',
    cursor_bg = '#F8F8F2',
    cursor_fg = '#282A36',
    cursor_border = '#F8F8F2',
    selection_bg = '#44475A',
    selection_fg = '#F8F8F2',
    ansi = { '#21222C', '#FF5555', '#50FA7B', '#F1FA8C', '#BD93F9', '#BD93F9', '#8BE9FD', '#F8F8F2' },
    brights = { '#6272A4', '#FF6E6E', '#69FF94', '#FFFFA5', '#D6ACFF', '#FF92DF', '#A4FFFF', '#FFFFFF' },
  },
  ['LIFEAI Claude'] = {
    foreground = '#F0D9C8',
    background = '#1A0F0A',
    cursor_bg = '#CC785C',
    cursor_fg = '#1A0F0A',
    cursor_border = '#CC785C',
    selection_bg = '#3D1F10',
    selection_fg = '#F0D9C8',
    ansi = { '#1A1A2E', '#E06C75', '#3ECF8E', '#E5C07B', '#61AFEF', '#C678DD', '#56B6C2', '#F0D9C8' },
    brights = { '#5A3A2A', '#FF7B86', '#6EF0B0', '#F0D09B', '#88C8FF', '#E090F0', '#7DD6E0', '#FFF5EE' },
  },
  ['LIFEAI Dark'] = {
    foreground = '#D4E9D4',
    background = '#0D1F17',
    cursor_bg = '#3ECF8E',
    cursor_fg = '#0D1F17',
    cursor_border = '#3ECF8E',
    selection_bg = '#1A6B3C',
    selection_fg = '#D4E9D4',
    ansi = { '#1A1A2E', '#E06C75', '#3ECF8E', '#E5C07B', '#61AFEF', '#C678DD', '#56B6C2', '#ABB2BF' },
    brights = { '#4A4A6A', '#FF7B86', '#6EF0B0', '#F0D09B', '#88C8FF', '#E090F0', '#7DD6E0', '#DCE4EF' },
  },
  ['LIFEAI Slate'] = {
    foreground = '#CDD6E0',
    background = '#0F1923',
    cursor_bg = '#61AFEF',
    cursor_fg = '#0F1923',
    cursor_border = '#61AFEF',
    selection_bg = '#1E3A5F',
    selection_fg = '#CDD6E0',
    ansi = { '#1A1A2E', '#E06C75', '#3ECF8E', '#E5C07B', '#61AFEF', '#C678DD', '#56B6C2', '#ABB2BF' },
    brights = { '#3A4A5A', '#FF7B86', '#6EF0B0', '#F0D09B', '#88C8FF', '#E090F0', '#7DD6E0', '#DCE4EF' },
  },
}

config.colors = {
  tab_bar = {
    background = '#11100F',
    active_tab = { bg_color = '#2A2723', fg_color = '#F0E8DC', intensity = 'Bold' },
    inactive_tab = { bg_color = '#181614', fg_color = '#B9B0A3' },
    inactive_tab_hover = { bg_color = '#332F2A', fg_color = '#F4EEE5' },
  },
}

config.tab_bar_style = {
  new_tab = wezterm.format {
    { Background = { Color = '#211F1B' } },
    { Foreground = { Color = '#D8D2C8' } },
    { Text = ' + ' },
  },
  new_tab_hover = wezterm.format {
    { Background = { Color = '#3A3631' } },
    { Foreground = { Color = '#F4EEE5' } },
    { Text = ' + ' },
  },
}

local tab_roles = {
  { pattern = 'codex', bg = '#1E3A5F', fg = '#DCE4EF' },
  { pattern = 'claude', bg = '#3D1F10', fg = '#FFF5EE' },
  { pattern = 'ccandme', bg = '#332F2A', fg = '#F4EEE5' },
  { pattern = 'portal', bg = '#1E3A5F', fg = '#DCE4EF' },
  { pattern = 'data', bg = '#1E3A5F', fg = '#DCE4EF' },
  { pattern = 'mktg', bg = '#1E3A5F', fg = '#DCE4EF' },
  { pattern = 'sv', bg = '#1A6B3C', fg = '#D4E9D4' },
  { pattern = 'cs2', bg = '#1A6B3C', fg = '#D4E9D4' },
  { pattern = 'infra', bg = '#1A6B3C', fg = '#D4E9D4' },
  { pattern = 'spec', bg = '#3D1F10', fg = '#FFF5EE' },
}

local function tab_title(tab)
  local title = tab.tab_title
  if title and #title > 0 then
    return title
  end
  return tab.active_pane.title
end

local fallback_tab_colors = {
  { bg = '#1E3A5F', fg = '#DCE4EF' },
  { bg = '#3D1F10', fg = '#FFF5EE' },
  { bg = '#1A6B3C', fg = '#D4E9D4' },
  { bg = '#332F2A', fg = '#F4EEE5' },
  { bg = '#4A315F', fg = '#F0E8DC' },
}

local function tab_palette(title, tab_index, is_active, hover)
  local lower = string.lower(title or '')
  for _, role in ipairs(tab_roles) do
    if string.find(lower, role.pattern, 1, true) then
      if is_active or hover then
        return role.bg, role.fg
      end
      return '#181614', role.fg
    end
  end

  local fallback = fallback_tab_colors[(tab_index % #fallback_tab_colors) + 1]
  if is_active or hover then
    return fallback.bg, fallback.fg
  end
  return '#181614', fallback.fg
end

wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  local title = tab_title(tab)
  local bg, fg = tab_palette(title, tab.tab_index, tab.is_active, hover)
  local edge = tab.is_active and '#B7A98F' or bg
  local label = ' ' .. tostring(tab.tab_index + 1) .. ': ' .. title .. ' '

  return wezterm.format {
    { Background = { Color = bg } },
    { Foreground = { Color = edge } },
    { Text = ' ' },
    { Background = { Color = bg } },
    { Foreground = { Color = fg } },
    { Text = wezterm.truncate_right(label, max_width) },
    { Background = { Color = bg } },
    { Foreground = { Color = edge } },
    { Text = ' ' },
  }
end)

config.launch_menu = {
  { label = 'PowerShell', cwd = repo, args = { 'pwsh.exe', '-NoLogo' } },
  { label = 'Command Prompt', cwd = repo, args = { 'cmd.exe' } },
  { label = 'SV', cwd = repo, args = pwsh_cell 'sv', set_environment_variables = { CELL_ROLE = 'sv', WEZTERM_COLOR_SCHEME = 'LIFEAI Dark' } },
  { label = 'Portal', cwd = repo, args = pwsh_cell 'cell-portal', set_environment_variables = { CELL_ROLE = 'cell-portal', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } },
  { label = 'Data', cwd = repo, args = pwsh_cell 'cell-data', set_environment_variables = { CELL_ROLE = 'cell-data', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } },
  { label = 'CS2', cwd = repo, args = pwsh_cell 'cell-cs2', set_environment_variables = { CELL_ROLE = 'cell-cs2', WEZTERM_COLOR_SCHEME = 'LIFEAI Dark' } },
  { label = 'Mktg', cwd = repo, args = pwsh_cell 'cell-mktg', set_environment_variables = { CELL_ROLE = 'cell-mktg', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } },
  { label = 'Infra', cwd = repo, args = pwsh_cell 'cell-infra', set_environment_variables = { CELL_ROLE = 'cell-infra', WEZTERM_COLOR_SCHEME = 'LIFEAI Dark' } },
  { label = 'Spec', cwd = repo, args = pwsh_cell 'specialist', set_environment_variables = { CELL_ROLE = 'specialist', WEZTERM_COLOR_SCHEME = 'LIFEAI Claude' } },
  { label = 'Claude', cwd = repo, args = pwsh_cell 'sv', set_environment_variables = { CELL_ROLE = 'sv', WEZTERM_COLOR_SCHEME = 'LIFEAI Claude' } },
  { label = 'Codex', cwd = repo, args = pwsh_cell 'codex', set_environment_variables = { CELL_ROLE = 'codex', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } },
  { label = 'CCandMe', cwd = ccandme, args = cmd_keep('cd /d ' .. ccandme .. ' && node ' .. ccandme .. '\\bin\\ccandme.mjs start'), set_environment_variables = { CELL_ROLE = 'ccandme' } },
  { label = 'VS Code', cwd = repo, args = { 'cmd.exe', '/c', 'start', '', code, repo } },
  { label = 'Co Develop Claude', cwd = repo, args = cmd_keep(appdata .. '\\clauth\\codevelop-claude.cmd'), set_environment_variables = { CELL_ROLE = 'codevelop-claude' } },
  { label = 'Co Develop Codex', cwd = repo, args = cmd_keep(appdata .. '\\clauth\\codevelop-codex.cmd'), set_environment_variables = { CELL_ROLE = 'codevelop-codex' } },
}

config.keys = {
  { key = 'r', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },
  { key = 't', mods = 'CTRL|SHIFT', action = act.SpawnTab 'CurrentPaneDomain' },
  { key = '=', mods = 'CTRL', action = act.IncreaseFontSize },
  { key = '+', mods = 'CTRL', action = act.IncreaseFontSize },
  { key = '-', mods = 'CTRL', action = act.DecreaseFontSize },
  { key = '0', mods = 'CTRL', action = act.ResetFontSize },
  { key = 'Tab', mods = 'CTRL', action = act.ActivateTabRelative(1) },
  { key = 'Tab', mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },
  { key = 'PageUp', mods = 'CTRL', action = act.ActivateTabRelative(-1) },
  { key = 'PageDown', mods = 'CTRL', action = act.ActivateTabRelative(1) },
  { key = 'l', mods = 'CTRL|SHIFT', action = act.ShowLauncherArgs { flags = 'LAUNCH_MENU_ITEMS|FUZZY' } },
  { key = 'p', mods = 'CTRL|SHIFT', action = act.ShowLauncherArgs { flags = 'COMMANDS|LAUNCH_MENU_ITEMS|TABS|FUZZY' } },
  { key = 'f', mods = 'CTRL|SHIFT', action = act.Search 'CurrentSelectionOrEmptyString' },
  {
    key = 'n',
    mods = 'CTRL|SHIFT',
    action = act.PromptInputLine {
      description = 'Name this tab',
      action = wezterm.action_callback(function(window, pane, line)
        if line then
          window:active_tab():set_title(line)
        end
      end),
    },
  },
  {
    key = 'e',
    mods = 'CTRL|ALT',
    action = wezterm.action_callback(function(window, pane)
      wezterm.background_child_process {
        'pwsh.exe',
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        edit_send,
        '-PaneId',
        tostring(pane:pane_id()),
      }
    end),
  },

  -- Build / rebuild the agent cockpit in this window (resume Claude + Codex,
  -- open the cell tabs). Uses the saved session manifest.
  {
    key = 'r',
    mods = 'CTRL|ALT',
    action = act.SpawnCommandInNewTab {
      cwd = repo,
      args = {
        'pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass',
        '-File', repo .. '\\scripts\\start-agent-cockpit.ps1', '-Workspace', 'regen',
      },
    },
  },

  { key = '1', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'sv', set_environment_variables = { CELL_ROLE = 'sv', WEZTERM_COLOR_SCHEME = 'LIFEAI Dark' } } },
  { key = '2', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'cell-portal', set_environment_variables = { CELL_ROLE = 'cell-portal', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } } },
  { key = '3', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'cell-data', set_environment_variables = { CELL_ROLE = 'cell-data', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } } },
  { key = '4', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'cell-cs2', set_environment_variables = { CELL_ROLE = 'cell-cs2', WEZTERM_COLOR_SCHEME = 'LIFEAI Dark' } } },
  { key = '5', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'cell-mktg', set_environment_variables = { CELL_ROLE = 'cell-mktg', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } } },
  { key = '6', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'cell-infra', set_environment_variables = { CELL_ROLE = 'cell-infra', WEZTERM_COLOR_SCHEME = 'LIFEAI Dark' } } },
  { key = '7', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'specialist', set_environment_variables = { CELL_ROLE = 'specialist', WEZTERM_COLOR_SCHEME = 'LIFEAI Claude' } } },
  { key = '8', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'codex', set_environment_variables = { CELL_ROLE = 'codex', WEZTERM_COLOR_SCHEME = 'LIFEAI Slate' } } },
  { key = '9', mods = 'ALT', action = act.SpawnCommandInNewTab { cwd = repo, args = pwsh_cell 'sv', set_environment_variables = { CELL_ROLE = 'sv', WEZTERM_COLOR_SCHEME = 'LIFEAI Claude' } } },

  { key = 'v', mods = 'CTRL|ALT', action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = 'h', mods = 'CTRL|SHIFT', action = act.SplitVertical { domain = 'CurrentPaneDomain' } },
  { key = 'd', mods = 'ALT|SHIFT', action = act.SplitPane { direction = 'Right', size = { Percent = 50 } } },
  { key = 'z', mods = 'CTRL|SHIFT', action = act.TogglePaneZoomState },
  { key = 'w', mods = 'CTRL|SHIFT', action = act.CloseCurrentPane { confirm = false } },

  { key = 'LeftArrow', mods = 'CTRL|ALT', action = act.ActivatePaneDirection 'Left' },
  { key = 'RightArrow', mods = 'CTRL|ALT', action = act.ActivatePaneDirection 'Right' },
  { key = 'UpArrow', mods = 'CTRL|ALT', action = act.ActivatePaneDirection 'Up' },
  { key = 'DownArrow', mods = 'CTRL|ALT', action = act.ActivatePaneDirection 'Down' },
  { key = 'LeftArrow', mods = 'CTRL|ALT|SHIFT', action = act.AdjustPaneSize { 'Left', 5 } },
  { key = 'RightArrow', mods = 'CTRL|ALT|SHIFT', action = act.AdjustPaneSize { 'Right', 5 } },

  {
    key = 'c',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      local has_selection = window:get_selection_text_for_pane(pane) ~= ''
      if has_selection then
        window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
        window:perform_action(act.ClearSelection, pane)
      else
        window:perform_action(act.SendKey { key = 'c', mods = 'CTRL' }, pane)
      end
    end),
  },
  { key = 'c', mods = 'CTRL|SHIFT', action = act.CopyTo 'ClipboardAndPrimarySelection' },
  { key = 'v', mods = 'CTRL', action = act.PasteFrom 'Clipboard' },
  { key = 'v', mods = 'CTRL|SHIFT', action = act.PasteFrom 'Clipboard' },
  { key = 'Enter', mods = 'SHIFT', action = act.SendString '\n' },
  { key = 'h', mods = 'SUPER', action = act.DisableDefaultAssignment },
  { key = 'Insert', mods = 'CTRL', action = act.CopyTo 'ClipboardAndPrimarySelection' },
  { key = 'Insert', mods = 'SHIFT', action = act.PasteFrom 'Clipboard' },
}

-- Agent cockpit auto-build:
-- When WezTerm starts directly into the `regen` workspace (e.g. via
-- `wezterm start --workspace regen`, or `wezterm-restart`), build the agent
-- cockpit: resume the saved Claude + Codex sessions and open the cell tabs.
-- Any other startup (default workspace, normal launch) is untouched.
local cockpit_script = repo .. '\\scripts\\start-agent-cockpit.ps1'
wezterm.on('gui-startup', function(cmd)
  local workspace = cmd and cmd.args == nil and (cmd.workspace or '') or ''
  -- mux is available regardless; check the active workspace name.
  local mux = wezterm.mux
  local ws = mux.get_active_workspace()
  if ws == 'regen' then
    mux.spawn_window {
      workspace = 'regen',
      cwd = repo,
      args = {
        'pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass',
        '-File', cockpit_script, '-Workspace', 'regen',
      },
    }
  end
end)

config.mouse_bindings = {
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'NONE',
    action = act.CompleteSelectionOrOpenLinkAtMouseCursor 'ClipboardAndPrimarySelection',
  },
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'SHIFT',
    action = act.CompleteSelection 'ClipboardAndPrimarySelection',
  },
  {
    event = { Down = { streak = 1, button = { WheelUp = 1 } } },
    mods = 'CTRL',
    action = act.IncreaseFontSize,
  },
  {
    event = { Down = { streak = 1, button = { WheelDown = 1 } } },
    mods = 'CTRL',
    action = act.DecreaseFontSize,
  },
}

return config
