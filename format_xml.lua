#!/usr/bin/env lua
-- format_xml.lua — valida, formata e regrava XML. Uso: lua format_xml.lua [-c] [ficheiro]

local arquivo_XML = "dicionariolatino.xml"
-- format_xml.lua — valida, formata e regrava XML. Uso: lua format_xml.lua [-c] [ficheiro.xml]
package.path = ((arg[0]:match("^(.*)/") or ".") .. "/src/?.lua;") .. package.path
local SLAXML = require "slaxdom"
local parse_opts, ser_opts = { strict = true, stripWhitespace = true }, { indent = 2 }

-- Localiza o primeiro erro estrutural (tag desequilibrada) no XML.
local function locate(xml)
  local stack, pos, line, line_start = {}, 1, 1, 1
  local function advance(to) for i = pos, to - 1 do if xml:byte(i) == 10 then line, line_start = line + 1, i + 1 end end; pos = to end
  while true do
    local open = xml:find("<", pos, true); if not open then break end; advance(open)
    local close = xml:find(">", open, true); if not close then break end
    local tag, col, next_pos = xml:sub(open, close), open - line_start + 1
    if     tag:sub(1,4) == "<!--"      then next_pos = (xml:find("-->", open, true) or close) + 3
    elseif tag:sub(1,9) == "<![CDATA[" then next_pos = (xml:find("]]>", open, true) or close) + 3
    elseif tag:match("^<[!?]")         then next_pos = close + 1
    else
      local slash, name = tag:match("^(</?)%s*([%w_:%.%-]+)")
      if slash == "</" then
        local top = stack[#stack]
        if not top then return line, col, "fechamento </"..name.."> sem abertura" end
        if top.name ~= name then return line, col, "esperado </"..top.name.."> (aberto na linha "..top.line.."), encontrado </"..name..">" end
        stack[#stack] = nil
      elseif name and not tag:match("/%s*>$") then stack[#stack+1] = { name = name, line = line } end
      next_pos = close + 1
    end
    advance(next_pos)
  end
  if #stack > 0 then local top = stack[#stack]; return top.line, 1, "elemento <"..top.name.."> não fechado" end
end

local file, check_only = arquivo_XML, false
for _, flag in ipairs(arg) do
  if     flag == "-c" or flag == "--check" then check_only = true
  elseif flag == "-h" or flag == "--help"  then print("Uso: lua "..arg[0].." [-c] [ficheiro.xml]"); os.exit(0)
  elseif flag:sub(1,1) == "-"              then io.stderr:write("opção inválida: "..flag.."\n"); os.exit(2)
  else   file = flag end
end

local f = assert(io.open(file, "r")); local xml = f:read("*a"); f:close()
local ok, dom = pcall(SLAXML.dom, SLAXML, xml, parse_opts)
if not ok then
  local msg, err_line, err_col, err_desc = tostring(dom), locate(xml)
  if err_line then msg = msg .. "\n  → linha "..err_line.." coluna "..err_col..": "..err_desc end
  io.stderr:write("[FAIL] "..file..":\n  "..msg.."\n"); os.exit(1)
end

local pretty = SLAXML:xml(dom, ser_opts)
if not pcall(SLAXML.dom, SLAXML, pretty, { strict = true }) then io.stderr:write("[FAIL] saída inválida\n"); os.exit(1) end
if check_only then print("[OK] "..file.." válido."); os.exit(0) end

local tmp = file..".tmp"; local out = assert(io.open(tmp, "w")); out:write(pretty); out:close()
assert(os.rename(tmp, file))
print("[OK] "..file.." formatado e regravado.")
