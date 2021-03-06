local GUI = require("GUI")
local system = require("System")
local component = require("Component")
local filesystem = require("Filesystem")
local internet = require("Internet")
local eeprom = component.eeprom

--------------------------------------------------------------------------------

local workspace = system.getWorkspace()
local localization = system.getLocalization(filesystem.path(system.getCurrentScript()) .. "Localizations/")
local container = GUI.addBackgroundContainer(workspace, true, true, "Cyan BIOS")
local readOnly = false
local config = {filesystem.getProxy().address, {}, 0}
-- delay loaded tables fail to deserialize cross [C] boundaries (such as when having to read files that cause yields)
local local_pairs = function(tbl)
  local mt = getmetatable(tbl)
  return (mt and mt.__pairs or pairs)(tbl)
end

-- Important: pretty formatting will allow presenting non-serializable values
-- but may generate output that cannot be unserialized back.
local function serialize(value, pretty)
  local kw =  {["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true,
               ["elseif"]=true, ["end"]=true, ["false"]=true, ["for"]=true,
               ["function"]=true, ["goto"]=true, ["if"]=true, ["in"]=true,
               ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
               ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true,
               ["until"]=true, ["while"]=true}
  local id = "^[%a_][%w_]*$"
  local ts = {}
  local result_pack = {}
  local function recurse(current_value, depth)
    local t = type(current_value)
    if t == "number" then
      if current_value ~= current_value then
        table.insert(result_pack, "0/0")
      elseif current_value == math.huge then
        table.insert(result_pack, "math.huge")
      elseif current_value == -math.huge then
        table.insert(result_pack, "-math.huge")
      else
        table.insert(result_pack, tostring(current_value))
      end
    elseif t == "string" then
      table.insert(result_pack, (string.format("%q", current_value):gsub("\\\n","\\n")))
    elseif
      t == "nil" or
      t == "boolean" or
      pretty and (t ~= "table" or (getmetatable(current_value) or {}).__tostring) then
      table.insert(result_pack, tostring(current_value))
    elseif t == "table" then
      if ts[current_value] then
        if pretty then
          table.insert(result_pack, "recursion")
          return
        else
          error("tables with cycles are not supported")
        end
      end
      ts[current_value] = true
      local f
      if pretty then
        local ks, sks, oks = {}, {}, {}
        for k in local_pairs(current_value) do
          if type(k) == "number" then
            table.insert(ks, k)
          elseif type(k) == "string" then
            table.insert(sks, k)
          else
            table.insert(oks, k)
          end
        end
        table.sort(ks)
        table.sort(sks)
        for _, k in ipairs(sks) do
          table.insert(ks, k)
        end
        for _, k in ipairs(oks) do
          table.insert(ks, k)
        end
        local n = 0
        f = table.pack(function()
          n = n + 1
          local k = ks[n]
          if k ~= nil then
            return k, current_value[k]
          else
            return nil
          end
        end)
      else
        f = table.pack(local_pairs(current_value))
      end
      local i = 1
      local first = true
      table.insert(result_pack, "{")
      for k, v in table.unpack(f) do
        if not first then
          table.insert(result_pack, ",")
          if pretty then
            table.insert(result_pack, "\n" .. string.rep(" ", depth))
          end
        end
        first = nil
        local tk = type(k)
        if tk == "number" and k == i then
          i = i + 1
          recurse(v, depth + 1)
        else
          if tk == "string" and not kw[k] and string.match(k, id) then
            table.insert(result_pack, k)
          else
            table.insert(result_pack, "[")
            recurse(k, depth + 1)
            table.insert(result_pack, "]")
          end
          table.insert(result_pack, "=")
          recurse(v, depth + 1)
        end
      end
      ts[current_value] = nil -- allow writing same table more than once
      table.insert(result_pack, "}")
    else
      error("unsupported type: " .. t)
    end
  end
  recurse(value, 1)
  local result = table.concat(result_pack)
  if pretty then
    local limit = type(pretty) == "number" and pretty or 10
    local truncate = 0
    while limit > 0 and truncate do
      truncate = string.find(result, "\n", truncate + 1, true)
      limit = limit - 1
    end
    if truncate then
      return result:sub(1, truncate) .. "..."
    end
  end
  return result
end

--------------------------------------------------------------------------------

local readOnlySwitch = container.layout:addChild(GUI.switchAndLabel(1, 1, 11 + unicode.len(localization.readOnly), 8, 0x8400FF, 0x1D1D1D, 0xFFFFFF, 0x878787, localization.readOnly, false))
local whiteListSwitch = container.layout:addChild(GUI.switchAndLabel(1, 4, 11 + unicode.len(localization.whitelist), 8, 0xFFA800, 0x1D1D1D, 0xFFFFFF, 0x878787, localization.whitelist, false))
local whitelistComboBox = container.layout:addChild(GUI.comboBox(3, 2, 30, 3, 0xEEEEEE, 0x2D2D2D, 0xCCCCCC, 0x888888))
local deleteUserButton = container.layout:addChild(GUI.roundedButton(1, 1, unicode.len(localization.deleteUser) + 8, 1, 0xFFFFFF, 0x000000, 0x878787, 0xFFFFFF, localization.deleteUser))
local userInput = container.layout:addChild(GUI.input(1, 1, 30, 3, 0xEEEEEE, 0x555555, 0x999999, 0xFFFFFF, 0x2D2D2D, "", localization.username))
local requireUserPressOnBootSwitch = container.layout:addChild(GUI.switchAndLabel(1, 4, 11 + unicode.len(localization.requireUserPressOnBoot), 8, 0x00fd01, 0x1D1D1D, 0xFFFFFF, 0x878787, localization.requireUserPressOnBoot, false))
local flashButton = container.layout:addChild(GUI.roundedButton(1, 1, unicode.len(localization.flash) + 8, 1, 0xFFFFFF, 0x000000, 0x878787, 0xFFFFFF, localization.flash))

userInput.validator = function()
    if #serialize(config) <= 256 then
        return true
    else
        GUI.alert(localization.freeSpaceLimit)
    end
end

userInput.onInputFinished = function()
    if #userInput.text > 0 then
        table.insert(config[2], userInput.text)
        whitelistComboBox:addItem(userInput.text)
        whitelistComboBox.hidden = false
        deleteUserButton.hidden = false
        userInput.text = ""
        workspace:draw()
    end
end

whiteListSwitch.switch.onStateChanged = function()
    requireUserPressOnBootSwitch.hidden = not requireUserPressOnBootSwitch.hidden
    config[3] = 0
    userInput.hidden = not userInput.hidden
    whitelistComboBox.hidden = true
    whitelistComboBox:clear()
    config[2] = {}
    workspace:draw()
end

deleteUserButton.onTouch = function()
    local username = whitelistComboBox:getItem(whitelistComboBox.selectedItem).text
    for i = 1, #config[2] do
        if config[2][i] == username then
            table.remove(config[2], i)
        end
    end
    whitelistComboBox:removeItem(whitelistComboBox.selectedItem)
    if whitelistComboBox:count() == 0 then
        whitelistComboBox:clear()
        deleteUserButton.hidden = true
        whitelistComboBox.hidden = true
    end
    workspace:draw()
end

whitelistComboBox.hidden = true
requireUserPressOnBootSwitch.hidden = true
userInput.hidden = true
deleteUserButton.hidden = true

requireUserPressOnBootSwitch.switch.onStateChanged = function()
    config[3] = config[3] == 0 and 1 or 0
end

readOnlySwitch.switch.onStateChanged = function()
    readOnly = not readOnly
end

flashButton.onTouch = function()
    whitelistComboBox:remove()
    whiteListSwitch:remove()
    requireUserPressOnBootSwitch:remove()
    userInput:remove()
    readOnlySwitch:remove()
    flashButton:remove()
    deleteUserButton:remove()
    local statusText

    local function status(text)
        if statusText then
            statusText:remove()
        end
        statusText = container.layout:addChild(GUI.text(1, 1, 0x878787, text))
        workspace:draw()
    end

    status(localization.downloading)
    local data, reason = internet.request("https://github.com/BrightYC/Cyan/blob/master/cyan.comp?raw=true")

    if data then
        filesystem.write(("/Mounts/%s/cyan"):format(computer.tmpAddress()), data)
    else
        GUI.alert(reason)
        container:remove()
    end

    status(localization.done)
    container.layout:addChild(GUI.roundedButton(1, 1, unicode.len(localization.reboot) + 8, 1, 0xFFFFFF, 0x000000, 0x878787, 0xFFFFFF, localization.reboot)).onTouch = function() 
        local success, reason = eeprom.set(([=[
[=[local a=[[%s]]local b=%s;local function c(d)return component.list(d)()and component.proxy(component.list(d)())end;local e=component.proxy(computer.tmpAddress())local f=c("eeprom")local g=c("gpu")local h,i;if g then h,i=g.maxResolution()g.setPaletteColor(9,0x002b36)g.setPaletteColor(11,0x8cb9c5)end;local function j(k,l,m,n,o)if g then g.setBackground(n or 0x002b36)g.setForeground(o or 0x8cb9c5)g.set(k,l,m)end end;local function p(k,l,q,r,n,o)if g then g.setBackground(n or 0x002b36)g.setForeground(o or 0x8cb9c5)g.fill(k,l,q,r," ")end end;local function s()if g then p(1,1,h,i)end end;local function t(u)return math.ceil(h/2-u/2)end;local function v(l,w,n,o)if g then j(t(unicode.len(w)),l,w,n,o)end end;local x,y,z,A,B=e.open("/cyan","r"),"","Cyan BIOS"s()if x then v(i/2-1,"Flashing...")v(i/2+1,"Please do not turn off the computer")while true do A=e.read(x,math.huge)if A then y=y..A else break end end;e.close(x)else B=true;v(i/2,"What an idiot... Fail-safe flashing (Lua BIOS)")y=[[local a;do local b=component.invoke;local function c(d,e,...)local f=table.pack(pcall(b,d,e,...))if not f[1]then return nil,f[2]else return table.unpack(f,2,f.n)end end;local g=component.list("eeprom")()computer.getBootAddress=function()return c(g,"getData")end;computer.setBootAddress=function(d)return c(g,"setData",d)end;do local h=component.list("screen")()local i=component.list("gpu")()if i and h then c(i,"bind",h)end end;local function j(d)local k,l=c(d,"open","/init.lua")if not k then return nil,l end;local m=""repeat local n,l=c(d,"read",k,math.huge)if not n and l then return nil,l end;m=m..(n or"")until not n;c(d,"close",k)return load(m,"=init")end;local l;if computer.getBootAddress()then a,l=j(computer.getBootAddress())end;if not a then computer.setBootAddress()for d in component.list("filesystem")do a,l=j(d)if a then computer.setBootAddress(d)break end end end;if not a then error("no bootable medium found"..(l and": "..tostring(l)or""),0)end;computer.beep(1000,0.2)end;a()]]z="EEPROM (Lua BIOS)"end;f.set(y)f.setLabel(z)if not B then f.setData(a)end;if b and not B then f.makeReadonly(f.getChecksum())end;if g then g.setPaletteColor(9,0x969696)g.setPaletteColor(11,0xb4b4b4)p(1,1,h,i,0x0000000)end;computer.shutdown(true)]=]):format(serialize(config), readOnly))
    
        if reason == "storage is readonly" then
            GUI.alert("EEPROM is read only. Please insert an not read-only EEPROM.")
            container:remove()
        else
            computer.shutdown(true)
        end 
    end
end

workspace:start(0)