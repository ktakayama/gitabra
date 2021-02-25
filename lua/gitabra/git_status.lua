local u = require("gitabra.util")
local chronos = require("chronos")
local job = require("gitabra.job")
local outliner = require("gitabra.outliner")
local api = vim.api

local function git_get_branch()
  return u.system_async('git branch --show-current', {splitlines=true})
end

local function git_branch_commit_msg()
  return u.system_async({"git", "show", "--no-patch", "--format='%h %s'"}, {splitlines=true})
end

local function git_status()
  return u.system_async("git status --porcelain", {splitlines=true})
end

local function git_diff()
  return u.system_async("git diff")
end

local function status_letter_name(letter)
  if "M" == letter then return "modified"
  elseif "A" == letter then return "added"
  elseif "D" == letter then return "deleted"
  elseif "R" == letter then return "renamed"
  elseif "C" == letter then return "copied"
  elseif "U" == letter then return "umerged"
  elseif "?" == letter then return "untracked"
  else return ""
  end
end

local function status_info()
  local funcname = debug.getinfo(1, "n").name
  print("ENTERING", funcname)

  local start = chronos.nanotime()
  local branch_j = git_get_branch()
  local branch_msg_j = git_branch_commit_msg()
  local status_j = git_status()
  local jobs = {branch_j, branch_msg_j, status_j}

  local wait_result = job.wait_all(1000, jobs)
  if not wait_result then
    error(string.format("%s: unable to complete git commands withint alotted time", funcname))
  end

  local stop = chronos.nanotime()
  print(string.format("git commands completed [%f]", stop-start))

  --------------------------------------------------------------------
  start = chronos.nanotime()

  local files = {}
  local untracked = {}
  local staged = {}
  local unstaged = {}

  for _, line in ipairs(status_j.output) do
    local fstat = line:sub(1, 2)
    local fname = line:sub(4)
    local entry = {
      index = status_letter_name(fstat:sub(1, 1)),
      working = status_letter_name(fstat:sub(2, 2)),
      name = fname,
    }

    if entry.working == "untracked" then
      table.insert(untracked, entry)
    end

    if entry.index ~= "" and entry.index ~= "untracked" then
      table.insert(staged, entry)
    end

    if entry.working ~= "" and entry.working ~= "untracked" then
      table.insert(unstaged, entry)
    end

    table.insert(files, entry)
  end

  stop = chronos.nanotime()
  print(string.format("Info reorg completed [%f]", stop-start))

  print("EXITING", funcname)
  return {
    header = string.format("[%s] %s", branch_j.output[1], branch_msg_j.output[1]:sub(2, -2)),
    files = files,
    untracked = untracked,
    staged = staged,
    unstaged = unstaged,
  }
end

local function setup_window()
  api.nvim_command("split")
  local win = api.nvim_get_current_win()
  return win
end

local function enable_custom_folding(win)
  vim.wo[win].foldmethod='expr'
  vim.wo[win].foldexpr='gitabra#foldexpr()'
  vim.wo[win].foldtext='gitabra#foldtext()'
end

local function disable_custom_folding(win)
  vim.wo[win].foldmethod='manual'
  vim.wo[win].foldexpr=''
  vim.wo[win].foldtext=''
end

local function setup_keybinds(bufnr)
  local function set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local opts = { noremap=true, silent=true }
  set_keymap('n', '<tab>', 'za', opts)
end

local function setup_buffer()
  local buf = vim.api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, 'GitabraStatus')
  vim.bo[buf].swapfile = false
  vim.bo[buf].buftype = 'nofile'
  -- vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'GitabraStatus'
  setup_keybinds(buf)
  return buf
end

local function setup_window_and_buffer()
  local buf = setup_buffer()
  local win = setup_window()
  api.nvim_set_current_buf(buf)
  return {
    winnr = win,
    bufnr = buf
  }
end

local current_status_screen

local function get_sole_status_screen()
  local sc = current_status_screen or {}

  -- Create a new window if the old one is invalid
  if not (sc.bufnr and api.nvim_buf_is_valid(sc.bufnr)) then
    sc.bufnr = setup_buffer()
  end

  -- Create a new buffer if the old one is invalid
  if not (sc.winnr and api.nvim_win_is_valid(sc.winnr)) then
    sc.winnr = setup_window()
  end

  api.nvim_set_current_win(sc.winnr)
  api.nvim_set_current_buf(sc.bufnr)
  current_status_screen = sc

  return current_status_screen
end

local function get_fold_level(lineno)
  lineno = lineno-1
  -- print("ENTERING git_status.get_fold_level: line", lineno)

  local sc = current_status_screen
  local outline = sc.outline

  -- PERF WARNING?
  -- This may be slow if the document being managed is somewhat large.
  local target_node = nil
  for node in u.table_depth_first_visit(outline.root) do

    if node.extmark_id then
      local position = api.nvim_buf_get_extmark_by_id(sc.bufnr, outliner.namespace_id, node.extmark_id, {})
      if position[1] == lineno then
        target_node = node
        break
      end
    end
  end

  if target_node then
    -- print("node:", vim.inspect(target_node))

    -- VIM wants to fold items of the same level together
    -- This means, get VIM to show the heading and to fold
    -- the rest of the child headings, both the parent heading
    -- and the child heading should have the same fold level.
    local depth = math.ceil(target_node.depth/2)
    local text = api.nvim_buf_get_lines(sc.bufnr, lineno, lineno+1, false)[1]

    print(string.format("(%i) [%i] %s", lineno, depth, text))

    -- print("EXITING git_status.get_fold_level:", target_node.depth)
    return depth
  else
    print(string.format("(%i) [%i] %s", lineno, depth, ""))
    -- print("EXITING git_status.get_fold_level:", "default")
    return 0
  end
end

local function get_fold_text()
  local sc = current_status_screen
  local foldstart = vim.v.foldstart-1
  local foldend = vim.v.foldend-1
  local text = api.nvim_buf_get_lines(sc.bufnr, foldstart, foldstart+1, false)[1]
  local count = foldend-foldstart
  return string.format("%s (%i)", text, count)
end

local function gitabra_status()

  local funcname = debug.getinfo(1, "n").name
  print("ENTERING", funcname)
  local info = status_info()

  local sc = get_sole_status_screen()

  --------------------------------------------------------------------
  print("Creating outline")
  local start = chronos.nanotime()
  local outline = outliner.new({buffer = sc.bufnr})

  -- We're going to add a bunch nodes/content to the buffer.
  -- For each node, we're going to add some text and an extmark on it.
  -- The extmark will be used for us to:
  -- 1. Figure out where to insert new nodes and text
  -- 2. Figure out the fold level of each line
  --
  -- We're disabling the folding here because of #2. If we don't
  -- disable folding here, nvim is going to immidately call `get_fold_level`
  -- as new lines are inserted. This will be before the extmark is setup,
  -- which means `get_fold_level` will not work properly.
  --
  -- This means that each time we're adding new content to the outline,
  -- we should disable the folding and re-enable it after all the
  -- inserts are done.
  disable_custom_folding(sc.winnr)

  -- print( vim.inspect(info))
  if info.header then
    outline:add_node(nil, {heading_text = info.header})
  end

  if #info.untracked ~= 0 then
    local section = outline:add_node(nil, {
        heading_text = "Untracked",
        id = "untracked",
    })
    for _, file in pairs(info.untracked) do
      outline:add_node(section, {heading_text = file.name})
    end
  end

  if #info.unstaged ~= 0 then
    -- print( "adding unstaged files:", #info.unstaged )
    local section = outline:add_node(nil, {
        heading_text = "Unstaged",
        id = "unstaged",
    })
    for _, file in pairs(info.unstaged) do
      -- print("adding unstaged file:", file.name)
      outline:add_node(section, {heading_text = file.name})
    end
  end

  if #info.staged ~= 0 then
    local section = outline:add_node(nil, {
        heading_text = "Staged",
        id = "Staged",
    })
    for _, file in pairs(info.staged) do
      outline:add_node(section, {heading_text = file.name})
    end
  end

  local stop = chronos.nanotime()
  print(string.format("Outline completed: [%f]", stop-start))

  -- Place the new outline into the global sc before any nodes & content are added.
  -- `get_fold_level` will be called by nvim as nodes are added to the outline.
  -- The global sc is the only way that function can find the currently active outline.
  sc.outline = outline
  enable_custom_folding(sc.winnr)
  --------------------------------------------------------------------
  local stop = chronos.nanotime()
  print("EXITING", funcname)
end

return {
  status_info = status_info,
  gitabra_status = gitabra_status,
  get_fold_level = get_fold_level,
  get_fold_text = get_fold_text,
  setup_window_and_buffer = setup_window_and_buffer,
  get_sole_status_screen = get_sole_status_screen,
}

--------------------------
-- Old Snippet
--
-- Setup a job to stream the contents of git-status to a new buffer
-- local buf = vim.api.nvim_create_buf(true, false)
-- local j = job:new({
-- 		cmd = "git status",
--   	on_stdout = function(self, err, data)
--     	if err then
--       	print("ERROR: "..err)
--     	end
--     	if data then
--       	for s in lines(data) do
--         	vim.api.nvim_buf_set_lines(buf, -1, -1, false, {s})
--       	end
--     	end
--   	end,
-- 	})
-- j:start()
