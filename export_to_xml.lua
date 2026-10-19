#!/usr/bin/env lua
-- export_to_xml.lua
--
-- Dumps every table of both SQLite databases into two XML files.
-- The XML shape is described by a small Mustache-like template below.
-- Requires only the `sqlite3` CLI in $PATH.
--
-- Usage:
--   lua export_to_xml.lua
--   luac -p export_to_xml.lua    -- só verifica sintaxe

----------------------------------------------------------------------
-- TEMPLATE  (the format description — edit here to change the XML)
----------------------------------------------------------------------
--
--   {{name}}               substitute a scalar
--   {{#list}}...{{/list}}  repeat the block for each item of `list`
--   {{^list}}...{{/list}}  render only when `list` is empty/false
--   {{! comment }}         ignored
--
-- A section tag alone on its own line has that line's whitespace and
-- newline stripped, so vertical formatting in the template does not
-- leak into the output.
--
-- Data exposed to the template:
--   name          database name (string)
--   file          database file path (string)
--   tables[]      one entry per SQLite table
--     name          table name
--     rows[]        one entry per row
--       fields[]      non-NULL columns: { name, value }
--       nulls[]       NULL columns:     { name }

local TEMPLATE_RDF = [[<?xml version="1.0" encoding="UTF-8"
?>
<rdf:RDF
    xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-
ns#"
    xmlns:lex="http://purl.org/lex#"
    xmlns:dcterms="http://purl.org/dc/terms/"
    xml:base="https://dicionariolatino.com/entry/">
{{#entries}}
  <lex:DictionaryEntry rdf:about="{{word_hash}}">
    <lex:lemma xml:lang="la">{{word}}</lex:lemma>
    <lex:headword xml:lang="la">{{word}}</lex:headword>-{{#found}}
    <lex:definition xml:lang="pt">{{definition}}</lex:d
efinition>
    <lex:rawHtml rdf:parseType="Literal">{{raw_html}}</lex:rawHtml>
{{/found}}
{{^found}}
    <lex:status>not-found</lex:status>
{{/found}}
    <dcterms:identifier>{{content_hash}}</dcterms:identifier>
{{#source_pdf}}
    <dcterms:source rdf:resource="https://dicionariolatino.com/{{source_pdf}}"/>
{{/source_pdf}}
  </lex:DictionaryEntry>
{{/entries}}
</rdf:RDF>
]]


local TEMPLATE = [==[<?xml version="1.0" encoding="UTF-8"?>
<database name="{{name}}" file="{{file}}">
{{#tables}}
  <table name="{{name}}">
{{#rows}}
    <row>
{{#fields}}
      <{{name}}>{{value}}</{{name}}>
{{/fields}}
{{#nulls}}
      <{{name}} null="true"/>
{{/nulls}}
    </row>
{{/rows}}
  </table>
{{/tables}}
</database>
]==]

----------------------------------------------------------------------
-- COLUMNS TO SKIP  (add names here to omit them from the dump)
----------------------------------------------------------------------

local SKIP_COLUMNS = {
  raw_html = true,
}

----------------------------------------------------------------------
-- TEMPLATE ENGINE  (Mustache-lite)
----------------------------------------------------------------------

-- Strip whitespace and newline around section tags that sit on their
-- own line.  This lets the template above stay readable without those
-- blank lines appearing in the output.
local function preprocess_standalone(tpl)
  local out = {}
  local pos = 1
  while pos <= #tpl do
    local eol = tpl:find("\n", pos, true)
    local line, next_pos
    if eol then
      line     = tpl:sub(pos, eol)   -- includes \n
      next_pos = eol + 1
    else
      line     = tpl:sub(pos)
      next_pos = #tpl + 1
    end
    local tag = line:match("^[ \t]*({{[#^/][^}]*}})[ \t]*\n$")
    if tag then
      out[#out + 1] = tag            -- drop the newline
    else
      out[#out + 1] = line
    end
    pos = next_pos
  end
  return table.concat(out)
end

-- Parse a template into a tree of nodes.
local function parse_template(tpl)
  tpl = preprocess_standalone(tpl)
  local root  = { children = {} }
  local stack = { root }
  local pos   = 1

  while true do
    local s, e = tpl:find("{{", pos, true)
    if not s then
      if pos <= #tpl then
        local top = stack[#stack]
        top.children[#top.children + 1] =
          { type = "text", value = tpl:sub(pos) }
      end
      break
    end
    if s > pos then
      local top = stack[#stack]
      top.children[#top.children + 1] =
        { type = "text", value = tpl:sub(pos, s - 1) }
    end
    local tag_end = tpl:find("}}", e + 1, true)
    if not tag_end then error("unclosed {{ tag at offset " .. s) end
    local raw = tpl:sub(e + 1, tag_end - 1)
    pos = tag_end + 2          -- skip BOTH closing braces

    local kind, name = "var", raw
    local c = raw:sub(1, 1)
    if     c == "#" then kind, name = "section", raw:sub(2)
    elseif c == "^" then kind, name = "inverse", raw:sub(2)
    elseif c == "/" then kind, name = "end",     raw:sub(2)
    elseif c == "!" then kind, name = "comment", ""
    end
    name = name:match("^%s*(.-)%s*$")

    if kind == "comment" then
      -- skip
    elseif kind == "end" then
      if #stack < 2 then error("unexpected {{/" .. name .. "}}") end
      local top = table.remove(stack)
      if top.name ~= name then
        error("mismatched {{/" .. name ..
              "}} (expected {{/" .. top.name .. "}})")
      end
    else
      local node = { type = kind, name = name, children = {} }
      local top = stack[#stack]
      top.children[#top.children + 1] = node
      if kind == "section" or kind == "inverse" then
        stack[#stack + 1] = node
      end
    end
  end
  if #stack > 1 then
    error("unclosed section {{#" .. stack[#stack].name .. "}}")
  end
  return root.children
end

-- Render a list of nodes against a scope table.
local function render_nodes(nodes, scope)
  local buf = {}
  for _, n in ipairs(nodes) do
    if n.type == "text" then
      buf[#buf + 1] = n.value

    elseif n.type == "var" then
      local v = scope[n.name]
      if type(v) == "string" or type(v) == "number" then
        buf[#buf + 1] = tostring(v)
      end

    elseif n.type == "section" then
      local v = scope[n.name]
      if type(v) == "table" then
        for _, item in ipairs(v) do
          local child = (type(item) == "table") and item or scope
          buf[#buf + 1] = render_nodes(n.children, child)
        end
      elseif v == true then
        buf[#buf + 1] = render_nodes(n.children, scope)
      end

    elseif n.type == "inverse" then
      local v = scope[n.name]
      if v == nil or v == false or (type(v) == "table" and #v == 0) then
        buf[#buf + 1] = render_nodes(n.children, scope)
      end
    end
  end
  return table.concat(buf)
end

local TEMPLATE_AST = parse_template(TEMPLATE)

local function render(scope)
  return render_nodes(TEMPLATE_AST, scope)
end

----------------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------------

local function xml_escape(s)
  if s == nil then return "" end
  s = tostring(s)
  s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
  s = s:gsub("&",  "&amp;")
  s = s:gsub("<",  "&lt;")
  s = s:gsub(">",  "&gt;")
  s = s:gsub('"',  "&quot;")
  s = s:gsub("'",  "&apos;")
  return s
end

local function hex_decode(s)
  if s == nil or s == "" then return "" end
  return (s:gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run_cmd(cmd)
  local f = io.popen(cmd, "r")
  if not f then return nil end
  local out = f:read("*a")
  f:close()
  return out
end

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
-- INTROSPECTION
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

local function table_columns(db, table_name)
  local out = sqlite(db, "PRAGMA table_info(" .. table_name .. ");")
  local cols = {}
  for line in out:gmatch("[^\r\n]+") do
    local name = line:match("^%d+|([^|]+)")
    if name and not SKIP_COLUMNS[name] then
      cols[#cols + 1] = name
    end
  end
  return cols
end

----------------------------------------------------------------------
-- ROW FETCHING  (NULL-safe, binary-safe)
----------------------------------------------------------------------

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
          row[col] = nil
        else
          row[col] = hex_decode(v)
        end
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

----------------------------------------------------------------------
-- BUILD TEMPLATE SCOPE
----------------------------------------------------------------------


local function is_found(row)

  -- if not row.definition then return false end
  -- if row.definition == "No Results Found.   Sorry :(" then return false end
  -- if row.content_hash == "32aaccb0c4597738cc2fca23b28557802587b9a9fa91d5c8c54beae8aedee5d9" then return false end
  return true
end

 local function build_scope_rdf(db_path, db_name)
  local entries = {}
  for _, table_name in ipairs(list_tables(db_path)) do
    local cols = table_columns(db_path, table_name)
    local has_word = false
    for _, c in ipairs(cols) do if c == "word" then has_word = true end end
    if has_word then
      for _, row in ipairs(fetch_rows(db_path, table_name, cols)) do
        local found = is_found(row)
        local source = nil
        if row.raw_html then
	   source = row.raw_html:match('href="(pagina/[^"]+)"')
        end
        entries[#entries + 1] = {
          word_hash    = xml_escape(row.word_hash),
          word         = xml_escape(row.word),
          content_hash = xml_escape(row.content_hash),
          found        = found,
          definition   = found and xml_escape(row.definition) or "",
          -- raw_html NÃO é escapado: parseType="Literal" quer o HTML real
          raw_html     = found and (row.raw_html or "") or "",
          source_pdf   = source and xml_escape(source) or "",
        }
      end
    end
  end
  return { entries = entries }
end


local function build_scope(db_path, db_name)
  local tables = {}
  for _, table_name in ipairs(list_tables(db_path)) do
    local cols = table_columns(db_path, table_name)
    local rows = {}
    for _, row in ipairs(fetch_rows(db_path, table_name, cols)) do
      local fields, nulls = {}, {}
      for _, col in ipairs(cols) do
        local v = row[col]
        if v == nil then
          nulls[#nulls + 1]  = { name = xml_escape(col) }
        else
          -- Insert a synthetic "lemma" field right before "word".
          -- In a Latin dictionary the "word" column IS the lemma,
          -- so we duplicate its value under a more explicit tag.
          if col == "word" then
            fields[#fields + 1] = {
              name  = "lemma",
              value = xml_escape(v),
            }
          end
          fields[#fields + 1] = { name = xml_escape(col),
                                  value = xml_escape(v) }
        end
      end
      rows[#rows + 1] = { fields = fields, nulls = nulls }
    end
    tables[#tables + 1] = { name = xml_escape(table_name), rows = rows }
  end
  return {
    name   = xml_escape(db_name),
    file   = xml_escape(db_path),
    tables = tables,
  }
end

----------------------------------------------------------------------
-- EXPORT
----------------------------------------------------------------------

local function export_db(db_path, out_path, db_name)
  local scope  = build_scope(db_path, db_name)
  local xml    = render(scope)
  local f, err = io.open(out_path, "w")
  if not f then error("cannot open " .. out_path .. ": " .. tostring(err)) end
  f:write(xml)
  f:close()
end

----------------------------------------------------------------------
-- MAIN
----------------------------------------------------------------------

local jobs = {
  {
    db   = "dicionariolatino.com/latin_portuguese." ..
             "4accb9e9ffd47e0856d7d7957f6548cbe531d8701d42c211431f746e6c2ada8a.db",
    out  = "dicionariolatino.xml",
    name = "dicionariolatino",
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
