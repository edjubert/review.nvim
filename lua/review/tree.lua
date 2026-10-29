local M = {}

function M.parents(path)
  local parts, parents = {}, {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  local prefix = ""
  for index = 1, #parts - 1 do
    prefix = prefix == "" and parts[index] or (prefix .. "/" .. parts[index])
    parents[#parents + 1] = prefix
  end
  return parents
end

function M.build(files)
  local root = { children = {}, directories = {}, source = files, path = "" }
  for index, file in ipairs(files) do
    local parent = root
    for _, path in ipairs(M.parents(file.new_path)) do
      local directory = parent.directories[path]
      if not directory then
        directory = {
          directory = path, path = path, name = path:match("[^/]+$"),
          parent = parent.path, children = {}, directories = {},
        }
        parent.directories[path] = directory
        parent.children[#parent.children + 1] = directory
      end
      parent = directory
    end
    parent.children[#parent.children + 1] = {
      file = index, path = file.new_path, name = file.new_path:match("[^/]+$"), parent = parent.path,
    }
  end
  local function sort(node)
    table.sort(node.children, function(a, b)
      if (a.directory ~= nil) ~= (b.directory ~= nil) then return a.directory ~= nil end
      return a.name < b.name
    end)
    for _, child in ipairs(node.children) do if child.directory then sort(child) end end
  end
  sort(root)
  return root
end

return M
