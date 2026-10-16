#!/usr/bin/env lua
-- export_sqlite_to_xml.lua
-- Dumps every table of both SQLite databases into two XML files.
-- Requires only the `sqlite3` CLI in $PATH (no Lua SQLite binding needed).
--
-- Usage:
--   lua export_sqlite_to_xml.lua
--   (or chmod +x and run ./export_sqlite_to_xml.lua)

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Escape a string for XML text / attribute content.
local function xml_escape(s)
  if s == nil then return "" end
  s = tostring(s)
  -- strip characters not allowed by XML 1.0
  s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("'", "&apos;")
  return s
end

-- Decode a hex string produced by SQLite's hex() into raw bytes.
local function hex_decode(s)
  if s == nil or s == "" then return "" end
  return (s:gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

-- Shell-quote a single argument (POSIX).
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Run a command and return stdout.
local function run_cmd(cmd)
  local f = io.popen(cmd, "r")
  if not f then return nil end
  local out = f:read("*a")
  f:close()
  return out
end

-- Run a SQL statement through sqlite3 CLI.
local function sqlite(db, sql, sep)
  local cmd
  if sep then
    cmd = string.format("sqlite3 -batch -noheader -separator %s %s %s",
      shell_quote(sep), shell_quote(db), shell_quote(sql))
  else
    cmd = string.format("sqlite3 -batch -noheader %s %s",
      shell_quote(db), shell_quote(sql))
  end
  return run_cmd(cmd) or ""
end

----------------------------------------------------------------------
-- Introspection
----------------------------------------------------------------------

local function list_tables(db)
  local out = sqlite(db,
    "SELECT name FROM sqlite_master " ..
    "WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
  local t = {}
  for line in out:gmatch("[^\r\n]+") do
    if line ~= "" then t[#t + 1] = line end
  end
  return t
end

local function table_columns(db, table)
  local out = sqlite(db, "PRAGMA table_info(" .. table .. ");")
  local cols = {}
  for line in out:gmatch("[^\r\n]+") do
    -- cid|name|type|notnull|dflt_value|pk
    local name = line:match("^%d+|([^|]+)")
    if name then cols[#cols + 1] = name end
  end
  return cols
end

----------------------------------------------------------------------
-- Row fetching (NULL-safe, binary-safe)
----------------------------------------------------------------------
-- We select each column as either the literal string "NULL" (when the
-- SQL value is NULL) or its hex() representation.  The hex() output
-- only ever contains [0-9A-F], so our chosen field separator "|" is
-- guaranteed not to collide with any value.

local SEP = "|"

local function fetch_rows(db, table_name, cols)
  local parts = {}
  for _, c in ipairs(cols) do
    parts[#parts + 1] = string.format(
      "CASE WHEN \"%s\" IS NULL THEN 'NULL' ELSE hex(\"%s\") END", c, c)
  end
  local sql = "SELECT " .. table.concat(parts, ", ") ..
              " FROM \"" .. table_name .. "\";"
  local out = sqlite(db, sql, SEP)

  local rows = {}
  for line in out:gmatch("[^\r\n]+") do
    local vals = {}
    local start = 1
    while true do
      local i = line:find(SEP, start, true)
      if not i then
        vals[#vals + 1] = line:sub(start)
        break
      end
      vals[#vals + 1] = line:sub(start, i - 1)
      start = i + 1
    end

    local row = {}
    for idx, v in ipairs(vals) do
      local col = cols[idx]
      if col then
        if v == "NULL" then
          row[col] = nil            -- SQL NULL
        else
          row[col] = hex_decode(v)  -- decoded bytes (UTF-8 text normally)
        end
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

----------------------------------------------------------------------
-- Export one database to XML
----------------------------------------------------------------------

local function export_db(db_path, out_path, db_name)
  local f, err = io.open(out_path, "w")
  if not f then
    error("cannot open " .. out_path .. ": " .. tostring(err))
  end

  f:write('<?xml version="1.0" encoding="UTF-8"?>\n')
  f:write(string.format('<database name="%s" file="%s">\n',
    xml_escape(db_name), xml_escape(db_path)))

  for _, table in ipairs(list_tables(db_path)) do
    local cols = table_columns(db_path, table)
    f:write(string.format('  <table name="%s">\n', xml_escape(table)))

    for _, row in ipairs(fetch_rows(db_path, table, cols)) do
      f:write('    <row>\n')
      for _, col in ipairs(cols) do
        local v = row[col]
        if v == nil then
          f:write(string.format('      <%s null="true"/>\n',
            xml_escape(col)))
        else
          f:write(string.format('      <%s>%s</%s>\n',
            xml_escape(col), xml_escape(v), xml_escape(col)))
        end
      end
      f:write('    </row>\n')
    end

    f:write('  </table>\n')
  end

  f:write('</database>\n')
  f:close()
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

local jobs = {
  {
    db   = "dicionariolatino.com/latin_portuguese."
             .. "4accb9e9ffd47e0856d7d7957f6548cbe531d8701d42c211431f746e6c2ada8a.db",
    out  = "dicionariolatino_dump.xml",
    name = "dicionariolatino",
  },
  {
    db   = "latin_to_narsese/narseses_latim_portugues.db",
    out  = "latin_to_narsese_dump.xml",
    name = "latin_to_narsese",
  },
}

for _, j in ipairs(jobs) do
  local ok, err = pcall(export_db, j.db, j.out, j.name)
  if ok then
    print(string.format("[OK]   %s  ->  %s", j.db, j.out))
  else
    io.stderr:write(string.format("[FAIL] %s : %s\n", j.db, tostring(err)))
  end
end

